import AppKit
import Testing
@testable import Parley

@MainActor struct TimelineStyleTests {
    private let me = Person(id: "me", name: "Me")
    private func row(_ text: String, from sender: Person) -> TimelineRow {
        TimelineRow.rows([Message(id: "m", conversationID: "c", sender: sender, text: text)])[0]
    }
    @Test func plainPutsEveryoneOnTheLeftWithAvatarAndNameAtTheRunStart() {
        let ownRow = row("hello", from: me)
        let bubbles = RowLayout.make(ownRow, width: 700, own: true, kind: .direct)
        let plain = RowLayout.make(ownRow, width: 700, own: true, kind: .direct, style: .plain)
        #expect(bubbles.bubble.midX > 350)                       // bubbles: own on the right
        #expect(plain.bubble.midX < 350)                         // plain: everyone on the left
        #expect(plain.avatar != nil && plain.name != nil)        // avatar and name start the run
        #expect(plain.avatar!.minY <= plain.bubble.minY + 4)     // the avatar sits at the top, beside the name
        #expect(!plain.tail)
    }
    @Test func plainRowsDrawNoBubble() {
        let view = MessageRowView(frame: NSRect(x: 0, y: 0, width: 600, height: 60))
        view.configure(row("hi", from: me), own: true, kind: .direct, meID: "me", style: .plain, actions: MessageRowActions())
        view.layout()   // laying out places every subview; the bubble must stay hidden
        #expect(view.bubbleView.isHidden)
        view.configure(row("hi", from: me), own: true, kind: .direct, meID: "me", style: .bubbles, actions: MessageRowActions())
        view.layout()
        #expect(!view.bubbleView.isHidden)
    }
}
