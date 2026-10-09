import Foundation
import Testing
@testable import Parley

extension AuthTests {
    private static func vault(_ cookies: [SessionCookie]) throws -> MemoryVault {
        let vault = MemoryVault()
        vault.write(try JSONEncoder().encode(WebCredentials(cookies: cookies, userAgent: "TestAgent/1")))
        return vault
    }
    private static let sid = SessionCookie(name: "SID", value: "test-session", domain: ".google.com", path: "/", secure: true, expires: -1)
    private static let channelURL = URL(string: "https://chat.google.com/webchannel/register")!

    @Test func bytesStreamsBodyAfterOneAuthRetry() async throws {
        let exchange = StubExchange([Self.xsrfReply, .init(status: 401), Self.xsrfReply, .init(data: Data("hello".utf8))])
        let auth = WebSessionAuthorizer(vault: try Self.vault([Self.sid]), session: AuthStubProtocol.session(exchange))
        let (stream, response) = try await auth.bytes(for: URLRequest(url: Self.channelURL))
        var body: [UInt8] = []
        for try await byte in stream { body.append(byte) }
        #expect(response.statusCode == 200 && body == Array("hello".utf8))
        #expect(exchange.requests.count == 4)
    }
    @Test func bytesRefusesOtherHosts() async throws {
        let auth = WebSessionAuthorizer(vault: try Self.vault([Self.sid]), session: AuthStubProtocol.session(StubExchange([])))
        await #expect(throws: AuthFailure.invalidDestination) {
            _ = try await auth.bytes(for: URLRequest(url: URL(string: "https://example.com/webchannel")!))
        }
    }
}

extension AuthTests {
    /// A refused request logs Google's reason: the body's readable text, without addresses or cookie values, kept short.
    @Test func aRefusedRequestsReasonIsReadableAndRedacted() {
        var body = Data([0x08, 0x03, 0x12, 0x2A])
        body += Data("INVALID_ARGUMENT: last_read_time is invalid for someone@example.com SID=abc".utf8)
        let reason = WebSessionAuthorizer.reason(body)
        #expect(reason.contains("INVALID_ARGUMENT: last_read_time is invalid"))
        #expect(!reason.contains("someone@example.com") && !reason.contains("abc") && reason.count <= 300)
        #expect(WebSessionAuthorizer.reason(Data([0, 1, 2, 3])) == "")
    }
}
