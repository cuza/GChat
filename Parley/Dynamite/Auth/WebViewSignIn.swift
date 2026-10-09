import AppKit
import Foundation
import OSLog
import WebKit

/// The sign-in window's website data, as `WebViewSignIn` uses it; tests replace it.
@MainActor protocol SignInWebData: AnyObject {
    func cookies() async -> [HTTPCookie]
    func removeAll() async
}
extension WKWebsiteDataStore: SignInWebData {
    func cookies() async -> [HTTPCookie] { await httpCookieStore.allCookies() }
    func removeAll() async { await removeData(ofTypes: Self.allWebsiteDataTypes(), modifiedSince: .distantPast) }
}

extension SessionCookie {
    init(_ cookie: HTTPCookie) {
        self.init(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                  secure: cookie.isSecure, expires: cookie.expiresDate?.timeIntervalSince1970 ?? -1)
    }
}

/// Google sign-in inside Parley: a web view with Parley's own persistent website data. Once Google hands the new session
/// to Google Chat, its cookies are checked and saved like any session. The Google Chat website itself is never used.
@MainActor @Observable
final class WebViewSignIn: NSObject, SignInBrowser, WKNavigationDelegate, WKUIDelegate {
    /// Parley's own website data, kept between sign-ins so Google can remember the account; cleared at sign-out.
    #if DEBUG   // the Debug build's own sign-in data, beside its own Keychain entry (see KeychainSessionVault)
    static let storeID = UUID(uuidString: "4F7A2C1E-9B3D-4E8A-A6C5-2D1F0B9E7C35")!
    #else
    static let storeID = UUID(uuidString: "4F7A2C1E-9B3D-4E8A-A6C5-2D1F0B9E7C34")!
    #endif
    static let start = URL(string: "https://chat.google.com/")!
    static let defaultSafariVersion = "26.0"

    private(set) var presented = false
    /// Google has handed the session to Google Chat: its website (which doesn't support this web view) stays hidden.
    private(set) var handingOff = false
    private(set) var webView: WKWebView?
    @ObservationIgnored private let data: any SignInWebData
    @ObservationIgnored private var lastOffered: (cookies: [String], at: Date)?
    @ObservationIgnored var now: () -> Date = { .now }

    init(data: any SignInWebData = WKWebsiteDataStore(forIdentifier: WebViewSignIn.storeID)) { self.data = data }

    func start() async throws {
        close()
        authLog.notice("In-app sign-in started")
        if let store = data as? WKWebsiteDataStore {   // tests' fake data opens no page
            let config = WKWebViewConfiguration()
            config.websiteDataStore = store
            let web = WKWebView(frame: .zero, configuration: config)   // WebKit's own user agent: nothing is spoofed here
            web.navigationDelegate = self; web.uiDelegate = self
            web.load(URLRequest(url: Self.start))
            webView = web
        }
        presented = true
    }
    func captureSession() async throws -> WebCredentials {
        guard presented else { throw AuthFailure.browserClosed }
        guard handingOff else { throw AuthFailure.chatNotOpen }
        let cookies = Self.sessionCookies(await data.cookies())
        guard Self.hasSession(cookies, now: now()) else { throw AuthFailure.chatNotOpen }
        // The same cookies again: wait for a change rather than asking Google every poll, but retry now and then.
        let key = cookies.map { "\($0.domain) \($0.path) \($0.name)=\($0.value)" }.sorted()
        if let lastOffered, lastOffered.cookies == key, now().timeIntervalSince(lastOffered.at) < 15 { throw AuthFailure.chatNotOpen }
        lastOffered = (key, now())
        return WebCredentials(cookies: cookies, userAgent: Self.safariUserAgent(version: Self.installedSafariVersion))
    }
    func close() {
        webView?.stopLoading()
        webView = nil
        presented = false; handingOff = false; lastOffered = nil
    }
    func forget() async {
        close()
        await data.removeAll()
    }
    /// Called once the page reaches Google Chat.
    func handOffBegan() {
        guard !handingOff else { return }
        handingOff = true
        authLog.notice("In-app sign-in: hand-off reached chat.google.com")
    }

    // MARK: Pure rules

    /// Only cookies Google Chat requests can carry.
    static func sessionCookies(_ cookies: [HTTPCookie]) -> [SessionCookie] {
        cookies.map(SessionCookie.init).filter {
            let domain = $0.domain.lowercased()
            return ["google.com", ".google.com", "chat.google.com", ".chat.google.com"].contains(domain)
        }
    }
    /// Google has finished the hand-off: a Google account cookie plus Google Chat's own OSID and COMPASS.
    static func hasSession(_ cookies: [SessionCookie], now: Date = .now) -> Bool {
        let sent = Set(cookies.filter { $0.applies(to: WebSessionAuthorizer.bootstrapURL, now: now) }.map(\.name))
        let compass = cookies.contains {
            $0.name == "COMPASS" && $0.domain.lowercased().hasSuffix("chat.google.com") && ($0.expires <= 0 || $0.expires > now.timeIntervalSince1970)
        }
        return (sent.contains("SID") || sent.contains("__Secure-1PSID")) && sent.contains("OSID") && compass
    }
    /// Google's sign-in pages stay in the window; a link the user clicks elsewhere opens in their browser. Redirects
    /// and form posts stay too, so a Workspace single sign-on provider's pages work.
    static func staysInView(_ url: URL, linkClick: Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about" { return true }
        guard scheme == "https" else { return false }
        return isGoogleSignInHost(url.host() ?? "") || !linkClick
    }
    static func isGoogleSignInHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return host.hasPrefix("accounts.google.") || ["accounts.youtube.com", "chat.google.com", "mail.google.com"].contains(host)
    }
    /// Safari's user agent, which Google Chat requires of the session's requests.
    static func safariUserAgent(version: String?) -> String {
        let version = version.flatMap { v in
            !v.isEmpty && v.count <= 16 && v.first!.isNumber && v.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") } ? v : nil
        } ?? defaultSafariVersion
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
    }
    static var installedSafariVersion: String? {
        Bundle(path: "/Applications/Safari.app")?.infoDictionary?["CFBundleShortVersionString"] as? String
    }
    /// Allow, without letting macOS hand the page to an app that claims the link (such as a Safari web app of
    /// Google Chat), which would interrupt the sign-in. WebKit's value one past `.download`.
    static let allowInView = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.download.rawValue + 1) ?? .allow

    // MARK: WebKit

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if action.targetFrame?.isMainFrame != false {
            guard Self.staysInView(url, linkClick: action.navigationType == .linkActivated) else {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            if url.host() == "chat.google.com", url.path().hasPrefix("/accounts/SetOSID") { handOffBegan() }
        }
        return Self.allowInView
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // Host only: no paths or query strings in the log.
        if let host = webView.url?.host() { authLog.notice("In-app sign-in: page from \(host, privacy: .public)") }
        if webView.url?.host() == "chat.google.com" { handOffBegan() }
    }
    /// A page opening a new window: Google's own pages load here, anything else in the user's browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if Self.staysInView(url, linkClick: true) { webView.load(URLRequest(url: url)) } else { NSWorkspace.shared.open(url) }
        }
        return nil
    }
}
