import Foundation
import Testing
@testable import Parley

struct RowLayoutTests {
    static let alex = Person(id: "alex", name: "Alex Example")
    static func row(_ text: String, sender: Person = alex, newDay: Bool = false, begins: Bool = true, ends: Bool = true,
                    configure: (inout Message) -> Void = { _ in }) -> TimelineRow {
        var message = Message(id: "m", conversationID: "c", sender: sender, text: text, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        configure(&message)
        return TimelineRow(message: message, begins: begins, ends: ends, newDay: newDay)
    }
    static let long = String(repeating: "A long message that wraps when the window is narrow. ", count: 8)

    @Test func sameInputSameLayout() {
        let row = Self.row(Self.long)
        #expect(RowLayout.make(row, width: 640, own: false, kind: .group) == RowLayout.make(row, width: 640, own: false, kind: .group))
    }
    @Test func wrappingFollowsWidth() {
        let row = Self.row(Self.long)
        let wide = RowLayout.make(row, width: 900, own: false, kind: .group), narrow = RowLayout.make(row, width: 400, own: false, kind: .group)
        #expect(narrow.height > wide.height)
        #expect(narrow.text!.height > wide.text!.height && narrow.bubble.width < wide.bubble.width)
        #expect(wide.bubble.width <= RowLayout.maxBubble)
    }
    @Test func aCardSitsBelowTheBubbleNotInsideIt() {
        let card = Attachment(name: "Plan", kind: .card, card: Card(sections: [[.text("Alex resolved a comment", [])], [.links([.init(title: "Open", url: URL(string: "https://example.com")!)])]]))
        let row = Self.row("Alex resolved a comment in Plan") { $0.attachments = [card] }
        for own in [false, true] {
            let layout = RowLayout.make(row, width: 700, own: own, kind: .space)
            let frame = layout.attachments[0]
            #expect(frame.minY >= layout.bubble.maxY + RowLayout.spacing)
            #expect(own ? frame.maxX == layout.bubble.maxX : frame.minX == layout.bubble.minX)
            #expect(layout.time.maxY <= layout.bubble.maxY && frame.maxY < layout.height)
            #expect(layout.avatar.map { $0.maxY == frame.maxY } ?? own)   // beside the card, the run's bottom
        }
    }
    @Test func everyElementLiesInsideTheBubbleAndTheRow() {
        let row = Self.row("Look at this", newDay: true) {
            $0.quote = QuotedMessage(sender: "Sam", text: Self.long)
            $0.attachments = [Attachment(name: "a.png", kind: .image, width: 1200, height: 800),
                              Attachment(name: "report.pdf", contentType: "application/pdf", kind: .file),
                              Attachment(name: "Example", kind: .link, url: URL(string: "https://example.com"), snippet: "A page", domain: "example.com")]
            $0.reactions = [Reaction(emoji: "👍", people: ["a", "b"]), Reaction(emoji: "❤️", people: ["me"])]
            $0.replyCount = 3; $0.edited = true; $0.delivery = .failed
        }
        for own in [false, true] {
            for width in [420.0, 700, 1100] {
                let layout = RowLayout.make(row, width: width, own: own, kind: .space)
                let inner = [layout.name, layout.quote, layout.quoteSender, layout.quoteText, layout.text, layout.replies, layout.time]
                    .compactMap { $0 } + layout.attachments + layout.reactions
                #expect(layout.attachments.count == 3 && layout.reactions.count == 2)
                for rect in inner { #expect(layout.bubble.contains(rect), "\(rect) outside bubble \(layout.bubble) at \(width), own \(own)") }
                for rect in [layout.quoteSender!, layout.quoteText!] { #expect(layout.quote!.contains(rect)) }
                let bounds = CGRect(x: 0, y: 0, width: width, height: layout.height)
                let tailed = layout.bubble.insetBy(dx: -RowLayout.tailWidth, dy: 0)
                for rect in [tailed, layout.dateHeader!, layout.retry!] + [layout.avatar].compactMap({ $0 }) {
                    #expect(bounds.contains(rect), "\(rect) outside row \(bounds)")
                }
                #expect(layout.dateHeader!.maxY <= layout.bubble.minY && layout.bubble.maxY <= layout.retry!.minY)
            }
        }
    }
    @Test func ownBubblesHugTheRightIncomingOnesTheLeftWithAnAvatar() {
        let row = Self.row("hello")
        let own = RowLayout.make(row, width: 700, own: true, kind: .group)
        #expect(own.bubble.maxX == 700 - RowLayout.margin - RowLayout.tailWidth && own.avatar == nil)
        let incoming = RowLayout.make(row, width: 700, own: false, kind: .group)
        #expect(incoming.avatar!.minX == RowLayout.margin && incoming.bubble.minX > incoming.avatar!.maxX)
        #expect(incoming.avatar!.maxY == incoming.bubble.maxY)
        #expect(RowLayout.make(row, width: 700, own: false, kind: .direct).avatar == nil)
        #expect(RowLayout.make(Self.row("hello", ends: false), width: 700, own: false, kind: .group).avatar == nil)
    }
    @Test func aDateHeaderAddsItsHeight() {
        let plain = RowLayout.make(Self.row("hi"), width: 600, own: false, kind: .group)
        let dated = RowLayout.make(Self.row("hi", newDay: true), width: 600, own: false, kind: .group)
        #expect(plain.dateHeader == nil)
        #expect(dated.height == plain.height + (dated.bubble.minY - plain.bubble.minY) && dated.height > plain.height)
    }
    @Test func theNameShowsOnARunsFirstIncomingBubbleInGroups() {
        #expect(RowLayout.make(Self.row("hi"), width: 600, own: false, kind: .group).name != nil)
        #expect(RowLayout.make(Self.row("hi"), width: 600, own: false, kind: .direct).name == nil)
        #expect(RowLayout.make(Self.row("hi"), width: 600, own: true, kind: .group).name == nil)
        #expect(RowLayout.make(Self.row("hi", begins: false), width: 600, own: false, kind: .group).name == nil)
    }
    @Test func theTimeSitsAfterTheLastLineWhenItFitsElseBelow() {
        var inline = 0, below = 0
        for count in 1...80 {
            let layout = RowLayout.make(Self.row(String(repeating: "word ", count: count).trimmingCharacters(in: .whitespaces)), width: 500, own: false, kind: .direct)
            let text = layout.text!
            if layout.time.minY < text.maxY {
                inline += 1
                #expect(layout.time.maxY == text.maxY)
            } else {
                below += 1
                #expect(layout.time.minY >= text.maxY)
            }
            #expect(layout.bubble.contains(layout.time))
        }
        #expect(inline > 0 && below > 0)
        let short = RowLayout.make(Self.row("ok"), width: 500, own: false, kind: .direct)
        #expect(short.time.minY < short.text!.maxY && short.time.minX >= short.text!.minX)
    }
    @Test func attachmentsTakeAttachmentViewsSizes() {
        let image = Attachment(name: "a.png", kind: .image, width: 1200, height: 800)
        #expect(RowLayout.attachmentSize(image) == image.mediaSize)
        #expect(image.mediaSize == CGSize(width: 320, height: CGFloat(800) * 320 / 1200))
        #expect(RowLayout.attachmentSize(Attachment(name: "x", kind: .link, domain: "e.com")).width == 320)
        #expect(RowLayout.attachmentSize(Attachment(name: String(repeating: "long name ", count: 20), kind: .file)).width == 280)
        // Seen live: in the narrow thread pane an image ran past the bubble's leading edge. Everything fits the bubble.
        let narrow = RowLayout.attachmentSize(image, maxWidth: 200)
        #expect(narrow.width == 200 && abs(narrow.height / narrow.width - 800.0 / 1200) < 0.01)
        #expect(RowLayout.attachmentSize(Attachment(name: "x", kind: .link, domain: "e.com"), maxWidth: 200).width == 200)
        #expect(RowLayout.attachmentSize(Attachment(name: String(repeating: "long name ", count: 20), kind: .file), maxWidth: 200).width == 200)
    }
}
