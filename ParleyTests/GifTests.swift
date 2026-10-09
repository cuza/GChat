import Foundation
import Testing
@testable import Parley

/// Answers every request on its own session with the next canned reply. Not the auth stub registry, so no serialization.
final class GiphyStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var replies: [String: (Int, Data)] = [:]   // keyed by a unique key query item
    nonisolated(unsafe) static var seen: [String: URLRequest] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "api_key" }?.value ?? ""
        Self.seen[key] = request
        let (status, body) = Self.replies[key] ?? (404, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GiphyStub.self]
        return URLSession(configuration: config)
    }
}

/// Trimmed from the documented GIF object (developers.giphy.com/docs/api/schema): sizes are strings.
let giphyFixture = Data("""
{"data":[{"type":"gif","id":"abc123","title":"Happy Dance GIF","rating":"g",
  "images":{"fixed_width":{"url":"https://media2.giphy.com/media/abc123/200w.gif","width":"200","height":"150","webp":"https://media2.giphy.com/media/abc123/200w.webp"},
            "original":{"url":"https://media2.giphy.com/media/abc123/giphy.gif","width":"480","height":"360","size":"1234567","mp4":"https://media2.giphy.com/media/abc123/giphy.mp4"}}},
  {"type":"gif","id":"broken","title":"no renditions","images":{}}],
 "pagination":{"total_count":2,"count":2,"offset":0},"meta":{"status":200,"msg":"OK","response_id":"r1"}}
""".utf8)

@MainActor struct GiphyTests {
    @Test func emptyQueryAsksForTrending() async throws {
        let key = "k-\(UUID())"
        GiphyStub.replies[key] = (200, giphyFixture)
        let gifs = try await Giphy.gifs(matching: "  ", key: key, session: GiphyStub.session)
        let url = try #require(GiphyStub.seen[key]?.url)
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.host() == "api.giphy.com" && url.path() == "/v1/gifs/trending")
        #expect(items["rating"] == "pg-13" && items["q"] == nil && items["limit"] != nil)
        #expect(gifs.map(\.id) == ["abc123"])   // a result without both renditions is dropped
    }
    @Test func searchSendsTheQueryAndDecodesRenditions() async throws {
        let key = "k-\(UUID())"
        GiphyStub.replies[key] = (200, giphyFixture)
        let gif = try #require(try await Giphy.gifs(matching: "happy dance", key: key, session: GiphyStub.session).first)
        let url = try #require(GiphyStub.seen[key]?.url)
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.path() == "/v1/gifs/search" && items["q"] == "happy dance" && items["rating"] == "pg-13" && items["api_key"] == key)
        #expect(gif.title == "Happy Dance GIF")
        #expect(gif.preview == Giphy.Rendition(url: URL(string: "https://media2.giphy.com/media/abc123/200w.gif")!, width: 200, height: 150))
        #expect(gif.original == Giphy.Rendition(url: URL(string: "https://media2.giphy.com/media/abc123/giphy.gif")!, width: 480, height: 360))
        let sent = gif.attachment
        #expect(sent.kind == .image && sent.contentType == "image/gif" && sent.url == gif.original.url && sent.thumbnailURL == gif.original.url)
        #expect(sent.width == 480 && sent.height == 360 && sent.name == "Happy Dance GIF")
    }
    @Test func rateLimitIsExplained() async throws {
        let key = "k-\(UUID())"
        GiphyStub.replies[key] = (429, Data())
        await #expect(throws: Giphy.Failure.rateLimited) { try await Giphy.gifs(matching: "x", key: key, session: GiphyStub.session) }
    }
}

struct GiphyKeyTests {
    @Test func theKeyRoundTripsThroughItsOwnKeychainItem() throws {
        let item = KeychainPassword(service: "dev.cuza.Parley.giphy.tests", account: "api-key")
        try item.set(nil)
        #expect(try item.get() == nil)
        try item.set("abc123")
        #expect(try item.get() == "abc123")
        try item.set("")          // clearing the field removes the item
        #expect(try item.get() == nil)
    }
}

@MainActor struct GifSendTests {
    /// The server drops a client-made URL chip for GIPHY links (the message arrives empty), so a GIF goes out as an upload.
    @Test func aPickedGifIsDownloadedAndSentAsAnUpload() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        let id = try #require(store.selectedID)
        let bytes = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0x80, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0x21, 0xF9, 4, 1, 0, 0, 0, 0,
                          0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 1, 0, 0x3B])   // a 1×1 GIF
        var asked: [URL] = []
        store.download = { asked.append($0); return bytes }
        let remote = URL(string: "https://media.giphy.com/media/abc/giphy.gif")!
        await store.sendGif(Attachment(name: "Party Cat", contentType: "image/gif", kind: .image, thumbnailURL: remote, url: remote, width: 1, height: 1),
                            conversation: id)
        #expect(asked == [remote])
        let draft = try #require(await fake.sentDrafts.last)
        #expect(draft.uploads.count == 1)
        #expect(draft.uploads.first?.contentType == "image/gif" && draft.uploads.first?.name == "Party Cat.gif")
    }
}
