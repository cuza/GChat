import AppKit
import Testing
@testable import Parley

/// Google Chat gives a picture a new token, so a new URL, every time its message loads: the cache keys a picture by its
/// message and place instead, and keeps it on disk, so a relaunch or a reload shows it without fetching it again.
@MainActor struct ImageDiskCacheTests {
    private static var png: Data {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { NSColor.red.setFill(); $0.fill(); return true }
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }
    private func picture(token: String) -> Parley.Attachment {
        var picture = Parley.Attachment(name: "cat.png", contentType: "image/png", kind: .image,
                                 thumbnailURL: URL(string: "https://chat.google.com/api/get_attachment_url?attachment_token=\(token)"))
        picture.cacheKey = "space/s/t1/m1#0"
        return picture
    }
    @Test func aPictureLoadsFromDiskWhateverItsTokenAfterARelaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ImageDiskCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = ImageCache.directory
        ImageCache.directory = folder
        defer { ImageCache.directory = saved }
        ImageCache.shared.removeAllObjects()
        var fetches = 0
        let fetch: (Parley.Attachment, Bool) async throws -> Data = { _, _ in fetches += 1; return Self.png }
        #expect(try await ImageCache.load(picture(token: "first"), fetch) != nil)
        ImageCache.shared.removeAllObjects()   // a relaunch: memory is empty, the disk is not
        #expect(try await ImageCache.load(picture(token: "second"), fetch) != nil)
        #expect(fetches == 1)
        #expect(ImageCache.key(picture(token: "first")) == ImageCache.key(picture(token: "second")))
    }
    @Test func pruningKeepsTheMostRecentlyUsedWithinTheLimitAndDropsOldOnes() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ImageDiskCachePrune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date.now
        func put(_ name: String, daysAgo: Double) throws {
            let file = folder.appending(path: name)
            try Data(count: 10_000).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: file.path)
        }
        try put("new", daysAgo: 0); try put("older", daysAgo: 1); try put("oldest", daysAgo: 2); try put("stale", daysAgo: 40)
        let one = try #require(folder.appending(path: "new").resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize)
        ImageCache.prune(folder, limit: one * 2, now: now)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == ["new", "older"])
    }
    @Test func messagesNameTheirPicturesByPlace() throws {
        let proto = Dynamite_Message.with { m in
            m.id.messageID = "m1"; m.id.parentID.topicID.topicID = "t1"; m.creator.userID.id = "u1"
            m.annotations = [.with { a in a.type = .uploadMetadata; a.uploadMetadata.attachmentToken = "tok"; a.uploadMetadata.contentType = "image/png"; a.uploadMetadata.contentName = "a.png" },
                             .with { a in a.type = .uploadMetadata; a.uploadMetadata.attachmentToken = "tok2"; a.uploadMetadata.contentType = "image/png"; a.uploadMetadata.contentName = "b.png" }]
        }
        let message = try #require(DynamiteMapper.message(proto, in: "space/s", selfID: "me", people: [:]))
        #expect(message.attachments.map(\.cacheKey) == ["\(message.id)#0", "\(message.id)#1"])
    }
}
