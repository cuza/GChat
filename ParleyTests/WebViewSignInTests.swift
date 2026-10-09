import Foundation
import Testing
@testable import Parley

/// The in-app sign-in's rules: which cookies it hands over, when, with which user agent, and which pages stay in it.
@MainActor struct WebViewSignInTests {
    private final class FakeData: SignInWebData {
        var stored: [HTTPCookie] = []
        var removals = 0
        func cookies() async -> [HTTPCookie] { stored }
        func removeAll() async { removals += 1; stored = [] }
    }
    private static func cookie(_ name: String, domain: String = ".google.com", path: String = "/", secure: Bool = true, expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "v-\(name)", .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }
    private static let handedOff = [cookie("SID"), cookie("__Secure-1PSID"), cookie("OSID", domain: "chat.google.com"),
                                    cookie("COMPASS", domain: "chat.google.com")]

    @Test func convertsWebKitCookies() {
        let expiry = (Date.now.timeIntervalSince1970 + 86_400).rounded(.down)   // WebKit caps expiries about a year out
        let persistent = SessionCookie(Self.cookie("SID", expires: Date(timeIntervalSince1970: expiry)))
        #expect(persistent == SessionCookie(name: "SID", value: "v-SID", domain: ".google.com", path: "/", secure: true, expires: expiry))
        let session = SessionCookie(Self.cookie("OSID", domain: "chat.google.com", path: "/u", secure: false))
        #expect(session.domain == "chat.google.com" && session.path == "/u" && !session.secure && session.expires == -1)
    }

    @Test func handsOverOnlyCookiesGoogleChatCanUse() {
        let all = Self.handedOff + [Self.cookie("LSID", domain: "accounts.google.com"), Self.cookie("VISITOR", domain: ".youtube.com"),
                                    Self.cookie("OSID", domain: "mail.google.com")]
        #expect(WebViewSignIn.sessionCookies(all).map(\.name) == ["SID", "__Secure-1PSID", "OSID", "COMPASS"])
    }

    @Test func signedInOnceGoogleChatHasItsCookies() {
        let cookies = Self.handedOff.map(SessionCookie.init)
        #expect(WebViewSignIn.hasSession(cookies))
        #expect(WebViewSignIn.hasSession(cookies.filter { $0.name != "SID" }))   // either account cookie will do
        #expect(!WebViewSignIn.hasSession(cookies.filter { $0.name != "SID" && $0.name != "__Secure-1PSID" }))
        #expect(!WebViewSignIn.hasSession(cookies.filter { $0.name != "OSID" }))
        #expect(!WebViewSignIn.hasSession(cookies.filter { $0.name != "COMPASS" }))
        // Mail's OSID is not Chat's.
        let mail = cookies.map { $0.name == "OSID" ? SessionCookie(name: "OSID", value: "x", domain: "mail.google.com", path: "/", secure: true, expires: -1) : $0 }
        #expect(!WebViewSignIn.hasSession(mail))
        let expired = cookies.map { var c = $0; c.expires = 10; return c }
        #expect(!WebViewSignIn.hasSession(expired, now: Date(timeIntervalSince1970: 100)))
    }

    @Test func keepsGoogleSignInPagesInTheWindow() {
        func stays(_ url: String, link: Bool = true) -> Bool { WebViewSignIn.staysInView(URL(string: url)!, linkClick: link) }
        #expect(stays("https://accounts.google.com/v3/signin/identifier"))
        #expect(stays("https://accounts.google.co.uk/accounts/SetSID"))
        #expect(stays("https://accounts.google.com.br/accounts/SetSID"))
        #expect(stays("https://accounts.youtube.com/accounts/SetSID"))
        #expect(stays("https://chat.google.com/accounts/SetOSID"))
        #expect(stays("https://mail.google.com/chat/"))
        #expect(stays("about:blank"))
        // A link the user clicks to another site opens in their browser…
        #expect(!stays("https://support.google.com/accounts/answer/1"))
        #expect(!stays("https://example.com/"))
        // …but a redirect or form post stays, as single sign-on providers need.
        #expect(stays("https://login.example-idp.com/saml", link: false))
        #expect(!stays("http://accounts.google.com/", link: false))
        #expect(!stays("mailto:someone@example.com"))
        #expect(!WebViewSignIn.isGoogleSignInHost("myaccounts.google.com"))
    }

    @Test func sendsSafarisUserAgent() {
        #expect(WebViewSignIn.safariUserAgent(version: "26.0.1")
                == "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0.1 Safari/605.1.15")
        for bad in [nil, "", "26.0 beta", "x26", "26.0\r\nX: y"] as [String?] {
            #expect(WebViewSignIn.safariUserAgent(version: bad).contains("Version/\(WebViewSignIn.defaultSafariVersion) Safari/605.1.15"))
        }
    }

    @Test func capturesOnlyAfterTheHandOff() async throws {
        let data = FakeData()
        data.stored = Self.handedOff
        let web = WebViewSignIn(data: data)
        try await web.start()
        // Cookies left from an earlier session don't count until Google hands this sign-in to Google Chat.
        await #expect(throws: AuthFailure.chatNotOpen) { try await web.captureSession() }
        web.handOffBegan()
        let credentials = try await web.captureSession()
        #expect(credentials.cookies.count == 4)
        #expect(credentials.userAgent.hasSuffix("Safari/605.1.15") && credentials.userAgent.contains("Version/"))
        // The same cookies are not offered again right away.
        await #expect(throws: AuthFailure.chatNotOpen) { try await web.captureSession() }
        web.close()
        await #expect(throws: AuthFailure.browserClosed) { try await web.captureSession() }
    }

    @Test func waitsForTheFullSession() async throws {
        let data = FakeData()
        data.stored = [Self.cookie("SID")]
        let web = WebViewSignIn(data: data)
        try await web.start()
        web.handOffBegan()
        await #expect(throws: AuthFailure.chatNotOpen) { try await web.captureSession() }
        data.stored = Self.handedOff
        #expect(try await web.captureSession().cookies.count == 4)
        web.close()
    }

    @Test func forgettingClearsTheWebsiteData() async {
        let data = FakeData()
        data.stored = Self.handedOff
        let web = WebViewSignIn(data: data)
        await web.forget()
        #expect(data.removals == 1 && data.stored.isEmpty && !web.presented)
    }
}
