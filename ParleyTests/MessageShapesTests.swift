import Foundation
import Testing
@testable import Parley

/// The anonymous report of message shapes Parley doesn't draw: structure only, never content.
struct MessageShapesTests {
    private func flagged(_ text: String = "Secret text for Alice", type: Int32 = 9) -> Dynamite_Message {
        .with { m in
            m.id.messageID = "msg-id-424242"; m.creator.userID.id = "user-id-777"; m.creator.email = "alice@example.com"
            m.textBody = text; m.messageType = .userMessage
            m.annotations = [.with { $0.type = .url; $0.startIndex = 0; $0.length = 4 }]
            m.botResponses = [.with { $0.type = type; $0.bot.name = "Secret App"; $0.setupURL = "https://setup.example.com/x" }]
        }
    }
    @Test func theSkeletonCarriesNoContent() throws {
        var store = MessageShapes.Store()
        let added = store.record(flagged(), fields: ["19.1=9"]); #expect(added)
        let json = try #require(String(data: MessageShapes.export(store.entries, app: "1.0 (1)", os: "15.0", date: Date(timeIntervalSince1970: 0)), encoding: .utf8))
        for secret in ["Secret", "Alice", "alice@example.com", "msg-id-424242", "user-id-777", "setup.example.com", "424242", "777"] {
            #expect(!json.contains(secret), "\(secret) leaked")
        }
        let skeleton = try #require(store.entries.first?.skeleton)
        #expect(skeleton.contains("28=1") && skeleton.contains("19{1=9") && skeleton.contains("11{1=1"))   // allow-listed enums kept
        #expect(skeleton.contains("10:L21"))   // the text: its length only
        #expect(store.entries.first?.fields == ["19.1=9"])
    }
    @Test func shapesAreDedupedAndCapped() {
        var store = MessageShapes.Store()
        let first = store.record(flagged("one"), fields: ["19.1=9"]); #expect(first)
        let again = store.record(flagged("a longer text"), fields: ["19.1=9"]); #expect(!again)   // same shape, another length
        let other = store.record(flagged(type: 5), fields: ["19.1=5"]); #expect(other)
        for i in 0..<300 { _ = store.record(flagged(), fields: ["x\(i)"]) }
        #expect(store.entries.count == MessageShapes.cap)
    }
    /// A Drive comment card: some comment rows, and a widget Parley doesn't draw (field `kind`: a chip list, a grid…).
    private func drive(rows: Int, kind: UInt8 = 21) throws -> Dynamite_Message {
        let key = Int(kind) << 3 | 2, tag: [UInt8] = key < 0x80 ? [UInt8(key)] : [UInt8(key & 0x7F | 0x80), UInt8(key >> 7)]
        let input = try Dynamite_CardWidget(serializedBytes: tag + [7, 0x0A, 0x05] + Array("Reply".utf8))
        return .with { m in
            m.id.messageID = "m\(rows)"; m.textBody = String(repeating: "mention ", count: rows)
            m.appAttachments = [.with { $0.card.sections = [.with { s in
                s.widgets = (0..<rows).map { i in .with { $0.decoratedText.text.html = "comment \(i)" } } + [input] }] }]
        }
    }
    private func flag(_ message: Dynamite_Message, in store: inout MessageShapes.Store) -> Bool {
        store.record(message, fields: DynamiteMapper.undrawn(message, selfID: "me"), parts: DynamiteMapper.undrawnParts(message))
    }
    @Test func oneGapIsOneEntryWhateverElseTheMessageHolds() throws {
        var store = MessageShapes.Store()
        let first = flag(try drive(rows: 1), in: &store), second = flag(try drive(rows: 4), in: &store)
        #expect(first && !second)
        #expect(store.entries.count == 1 && store.entries.first?.count == 2 && store.entries.first?.fields == ["15.7.2.2"])
        let other = flag(try drive(rows: 2, kind: 22), in: &store)   // another widget kind Parley doesn't draw
        #expect(other && store.entries.count == 2)
    }
    @Test func theLogLineNamesOnlyFields() {
        #expect(MessageShapes.logLine(["19.1=9", "35"]) == "a message has content Parley doesn't draw: fields 19.1=9, 35")
    }
}
