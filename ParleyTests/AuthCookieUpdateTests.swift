import Foundation
import Testing
@testable import Parley

/// Counts Keychain writes so tests can tell a real change from a no-op.
final class CountingVault: SessionVault, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    private var count = 0
    var writes: Int { lock.withLock { count } }
    func read() -> Data? { lock.withLock { value } }
    func write(_ data: Data) { lock.withLock { value = data; count += 1 } }
    func delete() { lock.withLock { value = nil } }
    func cookies() throws -> [SessionCookie] { try JSONDecoder().decode(WebCredentials.self, from: read()!).cookies }
}

extension AuthTests {
    private static let sid = SessionCookie(name: "SID", value: "test-session", domain: ".google.com", path: "/", secure: true, expires: -1)
    private static let sidcc = SessionCookie(name: "SIDCC", value: "old", domain: ".google.com", path: "/", secure: true, expires: -1)
    private static let apiURL = URL(string: "https://chat.google.com/api/get_self_user_status")!
    private static func response(_ setCookie: String) -> HTTPURLResponse {
        HTTPURLResponse(url: apiURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Set-Cookie": setCookie])!
    }
    private static func stored(_ cookies: [SessionCookie]) throws -> CountingVault {
        let vault = CountingVault()
        vault.write(try JSONEncoder().encode(WebCredentials(cookies: cookies, userAgent: "TestAgent/1")))
        return vault
    }

    @Test func setCookieUpdatesExistingCookieInPlace() {
        let merged = SessionCookie.merging([Self.sid, Self.sidcc], from: Self.response("SIDCC=new; Domain=.google.com; Path=/; Expires=Wed, 21 Oct 2099 07:28:00 GMT; Secure"))
        #expect(merged.map(\.name) == ["SID", "SIDCC"])
        #expect(merged[1].value == "new")
        #expect(merged[1].expires > Date.now.timeIntervalSince1970)
    }
    @Test func setCookieAddsNewChatAndGoogleCookies() {
        let merged = SessionCookie.merging([Self.sid], from: Self.response("COMPASS=dynamite=cs1; Path=/; Secure, NID=7; Domain=.google.com; Path=/"))
        #expect(merged.map(\.name) == ["SID", "COMPASS", "NID"])
        #expect(merged[1].domain == "chat.google.com" && merged[1].expires == -1 && merged[1].secure)
        #expect(SessionCookie.header(merged, for: Self.apiURL) == "COMPASS=dynamite=cs1; NID=7; SID=test-session")
    }
    @Test func expiredSetCookieDeletesTheCookie() {
        #expect(SessionCookie.merging([Self.sid, Self.sidcc], from: Self.response("SIDCC=; Domain=.google.com; Path=/; Max-Age=0")) == [Self.sid])
        #expect(SessionCookie.merging([Self.sid, Self.sidcc], from: Self.response("SIDCC=; Domain=.google.com; Path=/; Expires=Thu, 01 Jan 1970 00:00:01 GMT")) == [Self.sid])
        // A deletion only touches the same name, domain and path.
        #expect(SessionCookie.merging([Self.sid], from: Self.response("SID=; Domain=.google.com; Path=/other; Max-Age=0")) == [Self.sid])
    }
    @Test func setCookieForOtherDomainsIsIgnored() {
        let merged = SessionCookie.merging([Self.sid], from: Self.response("EVIL=x; Domain=evil.com; Path=/, YT=x; Domain=.youtube.com; Path=/, SID=hijack; Domain=.evilgoogle.com; Path=/"))
        #expect(merged == [Self.sid])
    }
    @Test func rpcSetCookieIsPersistedOncePerChange() async throws {
        let vault = try Self.stored([Self.sid, Self.sidcc])
        let rotate = StubExchange.Reply(headers: ["Set-Cookie": "SIDCC=new; Domain=.google.com; Path=/; Max-Age=31536000; Secure"])
        let exchange = StubExchange([Self.xsrfReply, rotate, rotate, .init()])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        for _ in 0..<3 { _ = try await auth.data(for: URLRequest(url: Self.apiURL)) }
        #expect(try vault.cookies().first { $0.name == "SIDCC" }?.value == "new")
        #expect(vault.writes == 2)   // the initial store plus one update; the repeat and the cookie-less reply write nothing
        #expect(exchange.requests.last?.value(forHTTPHeaderField: "Cookie") == "SID=test-session; SIDCC=new")
    }
    @Test func bootstrapSetCookieIsSavedAtSignIn() async throws {
        let vault = CountingVault()
        let exchange = StubExchange([.init(headers: ["Set-Cookie": "NID=9; Domain=.google.com; Path=/"], data: Self.xsrfReply.data)])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        try await auth.signIn(cookies: [Self.sid], userAgent: "test-agent")
        #expect(try vault.cookies().map(\.name) == ["SID", "NID"])
        #expect(vault.writes == 1)
    }
    @Test func retryAfterAuthFailureSendsTheUpdatedCookies() async throws {
        let vault = try Self.stored([Self.sid])
        let exchange = StubExchange([Self.xsrfReply, .init(status: 401, headers: ["Set-Cookie": "SID=rotated; Domain=.google.com; Path=/; Secure"]),
                                     Self.xsrfReply, .init()])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        _ = try await auth.data(for: URLRequest(url: Self.apiURL))
        #expect(exchange.requests[2].value(forHTTPHeaderField: "Cookie") == "SID=rotated")
        #expect(exchange.requests[3].value(forHTTPHeaderField: "Cookie") == "SID=rotated")
    }
    @Test func channelRegisterCompassIsStored() async throws {
        let vault = try Self.stored([Self.sid])
        let exchange = StubExchange([Self.xsrfReply, .init(headers: ["Set-Cookie": "COMPASS=dynamite=cs1; Path=/; Secure"])])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        _ = try await auth.data(for: URLRequest(url: URL(string: "https://chat.google.com/webchannel/register?rt=b")!))
        #expect(try vault.cookies().contains { $0.name == "COMPASS" && $0.value == "dynamite=cs1" && $0.domain == "chat.google.com" })
    }
    @Test func signedOutSessionIsNotResurrectedByALateResponse() async throws {
        let vault = try Self.stored([Self.sid])
        let exchange = StubExchange([Self.xsrfReply, .init(status: 302, headers: ["Location": "https://accounts.google.com/", "Set-Cookie": "NID=1; Domain=.google.com; Path=/"])])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        await #expect(throws: AuthFailure.signInRequired) { _ = try await auth.data(for: URLRequest(url: Self.apiURL)) }
        #expect(vault.read() == nil)
    }
}
