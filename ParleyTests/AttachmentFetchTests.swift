import AppKit
import Testing
@testable import Parley

/// Media fetches use the global stub registry, so they join the serialized AuthTests suite.
extension AuthTests {
    private static let image = Attachment(name: "cat.png", contentType: "image/png", kind: .image,
                                          thumbnailURL: URL(string: "https://chat.google.com/api/get_attachment_url?url_type=FIFE_URL&attachment_token=t"),
                                          url: URL(string: "https://chat.google.com/api/get_attachment_url?url_type=DOWNLOAD_URL&attachment_token=t"))
    private static func media(_ replies: [StubExchange.Reply]) throws -> (DynamiteBackend, StubExchange, MemoryVault) {
        let vault = MemoryVault()
        let cookie = SessionCookie(name: "SID", value: "test-session", domain: ".google.com", path: "/", secure: true, expires: -1)
        vault.write(try JSONEncoder().encode(WebCredentials(cookies: [cookie], userAgent: "TestAgent/1")))
        let exchange = StubExchange(replies)
        let session = AuthStubProtocol.session(exchange)
        let backend = DynamiteBackend(authorizer: WebSessionAuthorizer(vault: vault, session: session), realtime: false, vault: vault, media: session)
        return (backend, exchange, vault)
    }

    @Test func attachmentFollowsRedirectWithCookiesOnlyOnGoogleHosts() async throws {
        let (backend, exchange, _) = try Self.media([
            .init(status: 302, headers: ["Location": "https://lh3.googleusercontent.com/fife/abc=w640"]),
            .init(data: Data("png".utf8))
        ])
        #expect(try await backend.attachmentData(Self.image, thumbnail: true) == Data("png".utf8))
        let requests = exchange.requests
        #expect(requests.map(\.url) == [Self.image.thumbnailURL, URL(string: "https://lh3.googleusercontent.com/fife/abc=w640")])
        #expect(requests[0].value(forHTTPHeaderField: "Cookie") == "SID=test-session")
        #expect(requests[1].value(forHTTPHeaderField: "Cookie") == nil)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "TestAgent/1" })
    }
    @Test func customEmojiImageIsFetchedWithTheSession() async throws {
        let emoji = try #require(DynamiteMapper.customEmoji(.with { $0.uuid = "e"; $0.shortcode = "parrot"; $0.readToken = "r" }))
        let (backend, exchange, _) = try Self.media([.init(data: Data("png".utf8))])
        #expect(try await backend.attachmentData(try #require(emoji.image), thumbnail: true) == Data("png".utf8))
        #expect(exchange.requests.map(\.url) == [URL(string: "https://chat.google.com/api/get_custom_emoji_image?custom_emoji_read_token=r&rwa=true")])
        #expect(exchange.requests[0].value(forHTTPHeaderField: "Cookie") == "SID=test-session")
    }
    @Test func attachmentDownloadUsesFullURL() async throws {
        let (backend, exchange, _) = try Self.media([.init(data: Data("file".utf8))])
        _ = try await backend.attachmentData(Self.image, thumbnail: false)
        #expect(exchange.requests.map(\.url) == [Self.image.url])
    }
    @Test func attachmentRedirectToSignInFailsWithoutSigningOut() async throws {
        let (backend, _, vault) = try Self.media([.init(status: 302, headers: ["Location": "https://accounts.google.com/ServiceLogin"])])
        await #expect(throws: AuthFailure.signInRequired) { try await backend.attachmentData(Self.image, thumbnail: true) }
        #expect(vault.read() != nil)
    }
    @Test func attachmentRefusesPlainHTTPAndReportsHTTPErrors() async throws {
        let (backend, exchange, _) = try Self.media([.init(status: 302, headers: ["Location": "http://chat.google.com/x"]), .init(status: 404)])
        await #expect(throws: AuthFailure.invalidDestination) { try await backend.attachmentData(Self.image, thumbnail: true) }
        #expect(exchange.requests.count == 1)
        await #expect(throws: AuthFailure.http(404)) { try await backend.attachmentData(Self.image, thumbnail: false) }
    }
    @Test func attachmentNeedsAStoredSession() async throws {
        let empty = MemoryVault(), session = AuthStubProtocol.session(StubExchange([]))
        let backend = DynamiteBackend(authorizer: WebSessionAuthorizer(vault: empty, session: session), realtime: false, vault: empty, media: session)
        await #expect(throws: AuthFailure.signInRequired) { try await backend.attachmentData(Self.image, thumbnail: true) }
    }
}

struct FakeAttachmentTests {
    @Test func fakeBackendServesAnImageAndAFile() async throws {
        let backend = FakeBackend()
        let image = try await backend.attachmentData(Attachment(name: "a.png", contentType: "image/png", kind: .image, width: 40, height: 30), thumbnail: true)
        #expect(NSImage(data: image)?.size == NSSize(width: 40, height: 30))
        let file = try await backend.attachmentData(Attachment(name: "a.pdf", kind: .file), thumbnail: false)
        #expect(String(decoding: file, as: UTF8.self).contains("a.pdf"))
    }
}

