import Foundation
import WebKit

/// Renews the session without a window; tests replace it.
@MainActor protocol SessionRenewing: AnyObject {
    func renew() async throws -> WebCredentials
}

/// Opens Google Chat in a hidden web view on the sign-in window's own website data, as the Chat website keeps itself
/// signed in: Google's long-lived account cookies there carry the visit through to Google Chat, whose redirects hand
/// out fresh session cookies. A Google sign-in form on the way means Google wants the user, so the renewal stops.
@MainActor
final class SessionRenewer: NSObject, SessionRenewing, WKNavigationDelegate {
    private let data: any SignInWebData
    private var webView: WKWebView?
    private var reachedChat = false, wantsUser = false
    var timeout: Duration = .seconds(30)
    var poll: Duration = .milliseconds(500)
    /// Loads Google Chat; tests drive `reached(_:)` instead.
    var open: (@MainActor (SessionRenewer) -> Void)?

    init(data: any SignInWebData = WKWebsiteDataStore(forIdentifier: WebViewSignIn.storeID)) {
        self.data = data
        super.init()
        if let store = data as? WKWebsiteDataStore {
            open = { renewer in
                let config = WKWebViewConfiguration()
                config.websiteDataStore = store
                let web = WKWebView(frame: .zero, configuration: config)
                web.navigationDelegate = renewer
                web.load(URLRequest(url: WebViewSignIn.start))
                renewer.webView = web
            }
        }
    }

    func renew() async throws -> WebCredentials {
        reachedChat = false; wantsUser = false
        defer { webView?.stopLoading(); webView = nil }
        open?(self)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if wantsUser { throw AuthFailure.signInRequired }
            if reachedChat {
                let cookies = WebViewSignIn.sessionCookies(await data.cookies())
                if WebViewSignIn.hasSession(cookies) {
                    return WebCredentials(cookies: cookies, userAgent: WebViewSignIn.safariUserAgent(version: WebViewSignIn.installedSafariVersion))
                }
            }
            try await Task.sleep(for: poll)
        }
        throw AuthFailure.chatNotOpen
    }
    /// A main-frame page the visit reached.
    func reached(_ url: URL) {
        if Self.wantsUser(url) { wantsUser = true }
        if url.host()?.lowercased() == "chat.google.com" { reachedChat = true }
    }
    /// Google's sign-in pages that need the user (account chooser, password, challenges); its pass-through redirects
    /// (ServiceLogin with a live account, CheckCookie, SetOSID) carry on by themselves.
    static func wantsUser(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased(), host.hasPrefix("accounts.google.") else { return false }
        let path = url.path().lowercased()
        return ["/signin", "/v3/signin", "/challenge", "/accountchooser", "/servicelogin/identifier"].contains { path.hasPrefix($0) }
            || path.contains("/challenge/")
    }

    // MARK: WebKit

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard action.targetFrame?.isMainFrame != false else { return WebViewSignIn.allowInView }
        guard let url = action.request.url else { return .cancel }
        // Anywhere but Google's own pages (a Workspace single sign-on provider) also needs the user.
        guard url.scheme == "https", WebViewSignIn.isGoogleSignInHost(url.host() ?? "") else { wantsUser = true; return .cancel }
        reached(url)
        return wantsUser ? .cancel : WebViewSignIn.allowInView
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url { reached(url) }
    }
}
