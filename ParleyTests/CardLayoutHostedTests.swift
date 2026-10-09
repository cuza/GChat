import AppKit
import SwiftUI
import Testing
@testable import Parley

/// A card in a narrow column, hosted as the timeline hosts it: a row that doesn't wrap stays inside the card, cut with
/// "…", and a paragraph cut to two lines fills both and ends in "…", at the width the card is drawn.
@MainActor struct CardLayoutHostedTests {
    @Test func aNarrowCardKeepsItsTextInside() throws {
        let card = FakeBackend.shipyardPreview.card!
        let width: CGFloat = 300, size = CardLayout.size(card, maxWidth: width)
        // First as wide as a bubble can be, then narrowed, as opening the info pane narrows the timeline.
        let host = NSHostingView(rootView: CardView(card: card))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(host)
        host.frame = NSRect(origin: .zero, size: CardLayout.size(card, maxWidth: 500))
        host.layoutSubtreeIfNeeded()
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        func texts(_ view: NSView) -> [NSTextView] { ((view as? NSTextView).map { [$0] } ?? []) + view.subviews.flatMap(texts) }
        let views = texts(host)
        #expect(views.count == 2)
        for view in views {
            let frame = view.convert(view.bounds, to: host)
            #expect(frame.minX >= CardLayout.pad - 0.5 && frame.maxX <= width - CardLayout.pad + 0.5, "\(view.string.prefix(20)) at \(frame)")
            #expect(frame.maxY <= size.height + 0.5)
            // What it lays out fits its own width: nothing runs past the right edge.
            let manager = try #require(view.layoutManager), container = try #require(view.textContainer)
            manager.ensureLayout(for: container)
            #expect(manager.usedRect(for: container).width <= frame.width + 0.5, "\(view.string.prefix(20))")
        }
        let row = try #require(views.first { $0.string.hasPrefix("#42") })
        #expect(lines(row) == 2)   // the title on one line (cut), the label on the next
        let paragraph = try #require(views.first { !$0.string.hasPrefix("#42") })
        #expect(lines(paragraph) == 2 && paragraph.string.hasSuffix("…"))
        #expect(!paragraph.string.hasSuffix(" …"), "the cut leaves a space before the ellipsis")
        // Each text view lays out at its own width, so what it draws is what was measured.
        for view in views { #expect(view.textContainer?.size.width == view.bounds.width, "\(view.string.prefix(20))") }
    }
    /// The same card as the timeline draws it, in a row of a narrow column (the info pane open).
    @Test func aCardInANarrowRowKeepsItsTextInside() throws {
        let message = Message(id: "d6", conversationID: "design", sender: Person(id: "alex", name: "Alex Rivera"), text: "https://shipyard.example/pr/42",
                              createdAt: .now, attachments: [FakeBackend.shipyardPreview])
        let row = TimelineRow(message: message, begins: true, ends: true, newDay: false)
        let width: CGFloat = 380, layout = RowLayout.make(row, width: width, own: false, kind: .space)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: layout.height), styleMask: [.titled], backing: .buffered, defer: false)
        // Laid out wide first, then narrowed, as opening the info pane narrows the timeline under a row already drawn.
        let wide = RowLayout.make(row, width: 900, own: false, kind: .space)
        let view = MessageRowView(frame: NSRect(x: 0, y: 0, width: 900, height: wide.height))
        window.contentView?.addSubview(view)
        view.configure(row, own: false, kind: .space, meID: "me", actions: MessageRowActions())
        view.layout(); view.layoutSubtreeIfNeeded()
        view.frame = NSRect(x: 0, y: 0, width: width, height: layout.height)
        view.layout(); view.layoutSubtreeIfNeeded()
        let card = try #require(layout.attachments.first)
        func texts(_ view: NSView) -> [NSTextView] { ((view as? NSTextView).map { [$0] } ?? []) + view.subviews.flatMap(texts) }
        let inCard = texts(view).filter { $0 !== view.textView }
        #expect(inCard.count == 2)
        for text in inCard {
            let frame = text.convert(text.bounds, to: view)
            #expect(frame.minX >= card.minX + CardLayout.pad - 0.5 && frame.maxX <= card.maxX - CardLayout.pad + 0.5, "\(text.string.prefix(20)) at \(frame) in \(card)")
            let manager = try #require(text.layoutManager), container = try #require(text.textContainer)
            manager.ensureLayout(for: container)
            #expect(manager.usedRect(for: container).width <= frame.width + 0.5, "\(text.string.prefix(20)) lays out \(manager.usedRect(for: container).width) in \(frame.width)")
        }
        let paragraph = try #require(inCard.first { !$0.string.hasPrefix("#42") })
        #expect(lines(paragraph) == 2 && paragraph.string.hasSuffix("…"))
    }
    /// The demo window as the README's info shot shows it: the info pane narrows the timeline under the drawn card.
    @Test func openingTheInfoPaneKeepsTheCardsTextInside() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        await store.select("design")
        let host = NSHostingView(rootView: ChatView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1026, height: 713), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        func settle() async { for _ in 0..<5 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try? await Task.sleep(for: .milliseconds(100)) } }
        await settle()
        withAnimation { store.info = true }   // as the toolbar button opens it
        // Only the window's own display cycle, as in the app: no forced layout.
        for _ in 0..<20 { window.displayIfNeeded(); try? await Task.sleep(for: .milliseconds(100)) }
        func texts(_ view: NSView) -> [NSTextView] { ((view as? NSTextView).map { [$0] } ?? []) + view.subviews.flatMap(texts) }
        func hosts(_ view: NSView) -> [AttachmentHostView] { ((view as? AttachmentHostView).map { [$0] } ?? []) + view.subviews.flatMap(hosts) }
        let card = try #require(hosts(host).first { $0.attachment?.card?.by?.name == "Shipyard" })
        let inCard = texts(card)
        #expect(inCard.count == 2)
        // The title row and the paragraph start at the card's content edge, whatever width the card had before.
        for text in inCard { #expect(abs(text.convert(text.bounds, to: card).minX - CardLayout.pad) < 0.5, "\(text.string.prefix(20)) starts at \(text.convert(text.bounds, to: card).minX) in a \(card.bounds.width)-wide card") }
        for text in inCard {
            let frame = text.convert(text.bounds, to: card)
            #expect(frame.minX >= CardLayout.pad - 0.5 && frame.maxX <= card.bounds.width - CardLayout.pad + 0.5, "\(text.string.prefix(20)) at \(frame) in \(card.bounds)")
            let manager = try #require(text.layoutManager), container = try #require(text.textContainer)
            manager.ensureLayout(for: container)
            #expect(manager.usedRect(for: container).width <= frame.width + 0.5, "\(text.string.prefix(20)) lays out \(manager.usedRect(for: container).width) in \(frame.width)")
        }
        let paragraph = try #require(inCard.first { !$0.string.hasPrefix("#42") })
        #expect(lines(paragraph) == 2 && paragraph.string.hasSuffix("…"), "\(lines(paragraph)) lines: \(paragraph.string)")
    }
    private func lines(_ view: NSTextView) -> Int {
        guard let manager = view.layoutManager else { return 0 }
        var count = 0
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, _, _ in count += 1 }
        return count
    }
}
