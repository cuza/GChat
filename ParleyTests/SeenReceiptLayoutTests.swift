import AppKit
import Testing
@testable import Parley

/// "Seen" under my newest message a reader's receipt covers: part of the row's layout, drawn by the row view.
@MainActor struct SeenReceiptLayoutTests {
    private let me = Person(id: "me", name: "Dave")
    private func row(seenBy: [String]) -> TimelineRow {
        let message = Message(id: "m", conversationID: "c", sender: me, text: "hi", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        return TimelineRow.rows([message], seen: seenBy.isEmpty ? [:] : ["m": seenBy])[0]
    }

    @Test func rowsCarryTheirReaders() {
        #expect(row(seenBy: ["Maria Chen"]).seenBy == ["Maria Chen"] && row(seenBy: []).seenBy.isEmpty)
    }
    @Test func seenSitsUnderMyBubbleAndGrowsTheRow() throws {
        let plain = RowLayout.make(row(seenBy: []), width: 600, own: true, kind: .direct)
        let layout = RowLayout.make(row(seenBy: ["Maria Chen"]), width: 600, own: true, kind: .direct)
        #expect(plain.seen == nil)
        let seen = try #require(layout.seen)
        #expect(seen.minY >= layout.bubble.maxY && seen.maxX == layout.bubble.maxX)
        #expect(layout.height > plain.height && seen.maxY <= layout.height)
        #expect(layout.bubble == plain.bubble)
    }
    @Test func directSaysSeenGroupsNameTheReaders() {
        #expect(RowLayout.seenText(["Maria Chen"], kind: .direct).string == "Seen")
        #expect(RowLayout.seenText(["Maria Chen", "Alex Rivera"], kind: .group).string == "Seen by Maria, Alex")
    }
    @Test func theRowViewDrawsItAtItsFrame() {
        let row = row(seenBy: ["Maria Chen", "Alex Rivera"])
        let view = MessageRowView()
        view.configure(row, own: true, kind: .group, meID: "me", actions: MessageRowActions())
        view.frame = CGRect(x: 0, y: 0, width: 600, height: RowLayout.make(row, width: 600, own: true, kind: .group).height)
        view.layoutSubtreeIfNeeded()
        #expect(!view.seenLabel.isHidden && view.seenLabel.frame == view.rowLayout?.seen)
        #expect(view.seenLabel.text.string == "Seen by Maria, Alex")
        view.configure(self.row(seenBy: []), own: true, kind: .group, meID: "me", actions: MessageRowActions())
        view.layoutSubtreeIfNeeded()
        #expect(view.seenLabel.isHidden)
    }
    @Test func theMenuSaysWhoHasSeenMyMessage() {
        let view = MessageRowView()
        view.configure(row(seenBy: []), own: true, kind: .group, meID: "me", actions: MessageRowActions(readers: { _ in ["Maria Chen", "Alex Rivera"] }))
        let item = view.contextMenu().items.first { $0.title.hasPrefix("Seen by") }
        #expect(item?.title == "Seen by Maria Chen and Alex Rivera" && item?.isEnabled == false)
        view.configure(row(seenBy: []), own: true, kind: .group, meID: "me", actions: MessageRowActions())
        #expect(!view.contextMenu().items.contains { $0.title.hasPrefix("Seen by") })
    }
}
