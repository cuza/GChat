import Foundation
import Testing
@testable import Parley

/// After the fresh-token retry still fails, only Google's sign-in page ends the session.
extension AuthTests {
    private static let apiURL = URL(string: "https://chat.google.com/api/upload")!
    static let signInPage = StubExchange.Reply(status: 401, data: Data(#"<script>window.WIZ_global_data = {"qwAQke":"AccountsSignInUi","SNlM0e":""};</script>"#.utf8))
    private static func stored() throws -> MemoryVault {
        let vault = MemoryVault()
        let cookie = SessionCookie(name: "SID", value: "test-session", domain: ".google.com", path: "/", secure: true, expires: -1)
        vault.write(try JSONEncoder().encode(WebCredentials(cookies: [cookie], userAgent: "TestAgent/1")))
        return vault
    }

    @Test func signInPageAfterRetrySignsOut() async throws {
        let vault = try Self.stored()
        let exchange = StubExchange([Self.xsrfReply, .init(status: 401), Self.xsrfReply, Self.signInPage])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        await #expect(throws: AuthFailure.signInRequired) { _ = try await auth.data(for: URLRequest(url: Self.apiURL)) }
        #expect(exchange.requests.count == 4)
        #expect(vault.read() == nil)
    }
    @Test func signInPageOnTheStreamSignsOut() async throws {
        let vault = try Self.stored()
        let exchange = StubExchange([Self.xsrfReply, .init(status: 403), Self.xsrfReply, Self.signInPage])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        await #expect(throws: AuthFailure.signInRequired) { _ = try await auth.bytes(for: URLRequest(url: Self.apiURL)) }
        #expect(vault.read() == nil)
    }
    @Test func redirectToGoogleSignInAfterRetrySignsOut() async throws {
        let toAccounts = ["Location": "https://accounts.google.com/ServiceLogin?continue=https://chat.google.com/"]
        for last in [StubExchange.Reply(status: 302, headers: toAccounts), .init(status: 401, headers: toAccounts)] {
            let vault = try Self.stored()
            let exchange = StubExchange([Self.xsrfReply, .init(status: 401), Self.xsrfReply, last])
            let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
            await #expect(throws: AuthFailure.signInRequired) { _ = try await auth.data(for: URLRequest(url: Self.apiURL)) }
            #expect(vault.read() == nil)
        }
    }
    @Test func refusedRequestWithALiveSessionKeepsIt() async throws {
        let vault = try Self.stored()
        let refusal = StubExchange.Reply(status: 403, data: Data("<html><title>Error 403 (Forbidden)</title></html>".utf8))
        let exchange = StubExchange([Self.xsrfReply, refusal, Self.xsrfReply, refusal, Self.xsrfReply, .init(data: Data([1]))])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        await #expect(throws: AuthFailure.http(403)) { _ = try await auth.data(for: URLRequest(url: Self.apiURL)) }
        #expect(vault.read() != nil)
        // The next request bootstraps a new token and goes through.
        #expect(try await auth.data(for: URLRequest(url: Self.apiURL)).0 == Data([1]))
    }
    @Test func refusedStreamWithALiveSessionKeepsIt() async throws {
        let vault = try Self.stored()
        let exchange = StubExchange([Self.xsrfReply, .init(status: 401), Self.xsrfReply, .init(status: 401)])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        await #expect(throws: AuthFailure.http(401)) { _ = try await auth.bytes(for: URLRequest(url: Self.apiURL)) }
        #expect(vault.read() != nil)
    }
}

/// A proxy, captive portal or SSO gateway redirecting an API call is an HTTP error, not Google ending the session.
extension AuthTests {
    @Test func redirectElsewhereAfterRetryKeepsTheSession() async throws {
        let elsewhere = ["Location": "https://portal.example.com/login"]
        let vault = try Self.stored()
        let exchange = StubExchange([Self.xsrfReply, .init(status: 401), Self.xsrfReply, .init(status: 302, headers: elsewhere)])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        await #expect(throws: AuthFailure.http(302)) { _ = try await auth.data(for: URLRequest(url: Self.apiURL)) }
        #expect(vault.read() != nil)
    }
    @Test func onlyGoogleSignInEndsTheSession() {
        #expect(AuthFailure.bootstrapRedirect(AuthFailure.signInCategory).endsSession)
        #expect(!AuthFailure.bootstrapRedirect("an unexpected destination").endsSession)
        #expect(!AuthFailure.http(302).endsSession && AuthFailure.signInRequired.endsSession)
    }
}
