import AppKit
import Foundation
import SwiftProtobuf
import Testing
@testable import Parley

/// A small real PNG on disk, as the composer hands it over.
func temporaryImage(width: Int = 4, height: Int = 3, name: String = "shot.png") throws -> URL {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let folder = FileManager.default.temporaryDirectory.appending(path: "ParleyTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appending(path: name)
    try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    return url
}

/// Uploads go through the global stub registry, so they join the serialized AuthTests suite.
extension AuthTests {
    static let uploadSession = "https://chat.google.com/uploads?group_id=AAAA&upload_id=xyz&upload_protocol=resumable"
    static func uploadReplies(_ metadata: Dynamite_UploadMetadata) throws -> [StubExchange.Reply] {
        [.init(headers: ["X-Goog-Upload-Status": "active", "X-Goog-Upload-URL": uploadSession]),
         .init(headers: ["X-Goog-Upload-Status": "final"], data: Data((try metadata.serializedBytes() as Data).base64EncodedString().utf8))]
    }
    static let uploadedMetadata = Dynamite_UploadMetadata.with {
        $0.attachmentToken = "tok/en+=="
        $0.contentName = "shot.png"
        $0.contentType = "image/png"
        $0.originalDimension = .with { $0.width = 4; $0.height = 3 }
    }

    @Test func uploadStartsThenFinalizesOverTheWebSession() async throws {
        let file = try Attachment.localFile(at: try temporaryImage())
        let (backend, exchange) = try await Self.connected(try Self.uploadReplies(Self.uploadedMetadata))
        let uploaded = try await backend.upload(file, to: "space/AAAA", thread: nil)

        let requests = Array(exchange.requests.suffix(2))
        let start = requests[0], put = requests[1]
        #expect(start.url?.absoluteString == "https://chat.google.com/uploads?group_id=AAAA")
        #expect(start.httpMethod == "POST")
        #expect(start.value(forHTTPHeaderField: "X-Goog-Upload-Protocol") == "resumable")
        #expect(start.value(forHTTPHeaderField: "X-Goog-Upload-Command") == "start")
        #expect(start.value(forHTTPHeaderField: "X-Goog-Upload-File-Name") == "shot.png")
        #expect(start.value(forHTTPHeaderField: "X-Goog-Upload-Content-Type") == "image/png")
        let bytes = try Data(contentsOf: try #require(file.url))
        #expect(start.value(forHTTPHeaderField: "X-Goog-Upload-Content-Length") == String(bytes.count))
        #expect(put.url?.absoluteString == Self.uploadSession)
        #expect(put.httpMethod == "PUT")
        #expect(put.value(forHTTPHeaderField: "X-Goog-Upload-Command") == "upload, finalize")
        #expect(put.value(forHTTPHeaderField: "X-Goog-Upload-Offset") == "0")
        #expect(Self.body(put) == bytes)
        for request in requests {   // the session's credentials, as every RPC sends them
            #expect(request.value(forHTTPHeaderField: "Cookie") == "SID=test-session")
            #expect(request.value(forHTTPHeaderField: "X-Framework-XSRF-Token") == "test-xsrf")
        }
        let token = try #require(uploaded.uploadToken)
        #expect(try Dynamite_UploadMetadata(serializedBytes: try #require(Data(base64Encoded: token))) == Self.uploadedMetadata)
        #expect(uploaded.url == file.url && uploaded.name == file.name)
    }
    @Test func replyUploadsNameTheTopicAndDMsUseTheBareID() async throws {
        let file = try Attachment.localFile(at: try temporaryImage())
        let (backend, exchange) = try await Self.connected(try Self.uploadReplies(Self.uploadedMetadata))
        _ = try await backend.upload(file, to: "dm/xyz", thread: "dm/xyz/t1/t1")
        let start = try #require(exchange.requests.dropLast().last)
        #expect(start.url?.absoluteString == "https://chat.google.com/uploads?group_id=xyz&topic_id=t1")
    }
    @Test func uploadRefusesASessionURLOffChat() async throws {
        let file = try Attachment.localFile(at: try temporaryImage())
        let (backend, exchange) = try await Self.connected([.init(headers: ["X-Goog-Upload-Status": "active", "X-Goog-Upload-URL": "https://evil.example.com/up"])])
        let before = exchange.requests.count
        await #expect(throws: AuthFailure.invalidDestination) { try await backend.upload(file, to: "space/AAAA", thread: nil) }
        #expect(exchange.requests.count == before + 1)   // only the start: the file never left
    }
    @Test func uploadNeedsAnActiveSessionAndAFinalMetadataReply() async throws {
        let file = try Attachment.localFile(at: try temporaryImage())
        let (backend, _) = try await Self.connected([
            .init(headers: ["X-Goog-Upload-Status": "final"]),
            .init(headers: ["X-Goog-Upload-Status": "active", "X-Goog-Upload-URL": Self.uploadSession]), .init(headers: ["X-Goog-Upload-Status": "final"], data: Data("not base64 proto!".utf8))
        ])
        await #expect(throws: AuthFailure.unexpectedResponse) { try await backend.upload(file, to: "space/AAAA", thread: nil) }
        await #expect(throws: AuthFailure.malformedProto) { try await backend.upload(file, to: "space/AAAA", thread: nil) }
    }
    @Test func sendCarriesUploadsAsUploadMetadataChips() async throws {
        let topic = try Self.proto(Dynamite_CreateTopicResponse.with { $0.topic.replies = [Self.message("m9", topic: "m9", at: 5, by: "me")] })
        let reply = try Self.proto(Dynamite_CreateMessageResponse.with { $0.message = Self.message("r9", topic: "m9", at: 6, by: "me") })
        let (backend, exchange) = try await Self.connected([topic, reply])
        // Field 22 = 2 appended: fields Parley doesn't model go back untouched.
        let bytes: Data = try Self.uploadedMetadata.serializedBytes() + Data([0xB0, 0x01, 0x02])
        let metadata = try Dynamite_UploadMetadata(serializedBytes: bytes)
        #expect(metadata != Self.uploadedMetadata)
        var file = Attachment(name: "shot.png", contentType: "image/png", kind: .image, url: URL(fileURLWithPath: "/tmp/shot.png"))
        file.uploadToken = bytes.base64EncodedString()
        let sent = try await backend.send(MessageDraft(text: "", localID: "local-1", uploads: [file]), to: "space/AAAA", thread: nil)
        _ = try await backend.send(MessageDraft(text: "look", localID: "local-2", uploads: [file]), to: "space/AAAA", thread: sent.id)

        let topicRequest = try Dynamite_CreateTopicRequest(serializedBytes: Self.body(try #require(exchange.requests.first { $0.url?.path == "/api/create_topic" })))
        let replyRequest = try Dynamite_CreateMessageRequest(serializedBytes: Self.body(try #require(exchange.requests.first { $0.url?.path == "/api/create_message" })))
        #expect(topicRequest.textBody.isEmpty && replyRequest.textBody == "look")
        for annotations in [topicRequest.annotations, replyRequest.annotations] {
            let chip = try #require(annotations.first)
            #expect(annotations.count == 1)
            #expect(chip.type == .uploadMetadata && chip.chipRenderType == .render)
            #expect(chip.uploadMetadata == metadata)
            #expect(try chip.uploadMetadata.serializedBytes() == bytes)
            #expect(!chip.hasStartIndex && !chip.hasLength)
        }
    }
    @Test func sendRefusesAnUploadWithoutItsMetadata() async throws {
        let (backend, exchange) = try await Self.connected()
        let before = exchange.requests.count
        let file = Attachment(name: "a.pdf", kind: .file, url: URL(fileURLWithPath: "/tmp/a.pdf"))
        await #expect(throws: AuthFailure.malformedProto) { try await backend.send(MessageDraft(text: "", localID: "l", uploads: [file]), to: "space/AAAA", thread: nil) }
        #expect(exchange.requests.count == before)
    }
}

struct LocalFileTests {
    @Test func imagesKeepTypeAndPixelSize() throws {
        let file = try Attachment.localFile(at: try temporaryImage(width: 40, height: 30))
        #expect(file.kind == .image && file.contentType == "image/png" && file.name == "shot.png")
        #expect(file.width == 40 && file.height == 30)
        #expect(file.isLocalFile && file.uploadToken == nil)
    }
    @Test func otherFilesAreChips() throws {
        let url = try temporaryImage().deletingLastPathComponent().appending(path: "notes.pdf")
        try Data("%PDF-1.4".utf8).write(to: url)
        let file = try Attachment.localFile(at: url)
        #expect(file.kind == .file && file.contentType == "application/pdf" && file.width == nil)
    }
    @Test func emptyFoldersAndOversizedFilesAreRefused() throws {
        let folder = try temporaryImage().deletingLastPathComponent()
        #expect(throws: AttachmentError.notAFile(folder.lastPathComponent)) { try Attachment.localFile(at: folder) }
        let empty = folder.appending(path: "empty.txt")
        try Data().write(to: empty)
        #expect(throws: AttachmentError.empty("empty.txt")) { try Attachment.localFile(at: empty) }
        let big = folder.appending(path: "big.mov")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(Attachment.maxUploadBytes + 1))   // sparse: no 200 MB written
        try handle.close()
        #expect(throws: AttachmentError.tooLarge("big.mov")) { try Attachment.localFile(at: big) }
        #expect(AttachmentError.tooLarge("big.mov").localizedDescription.contains("200 MB"))
    }
}
