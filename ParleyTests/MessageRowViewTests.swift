import AppKit
import Testing
@testable import Parley

@MainActor struct MessageRowViewTests {
    let row = RowLayoutTests.row(RowLayoutTests.long, newDay: true) {
        $0.quote = QuotedMessage(sender: "Sam", text: "the original")
        $0.attachments = [Attachment(name: "a.png", kind: .image, width: 1200, height: 800), Attachment(name: "notes.txt", kind: .file)]
        $0.reactions = [Reaction(emoji: "👍", people: ["me"]), Reaction(emoji: "🎉", people: ["alex"])]
        $0.replyCount = 2; $0.delivery = .failed
    }
    private func view(width: CGFloat, own: Bool = false, actions: MessageRowActions = MessageRowActions()) -> MessageRowView {
        let view = MessageRowView()
        view.configure(row, own: own, kind: .space, meID: "me", actions: actions)
        view.frame = CGRect(x: 0, y: 0, width: width, height: RowLayout.make(row, width: width, own: own, kind: .space).height)
        view.layoutSubtreeIfNeeded()
        return view
    }
    private func expectPlaced(_ view: MessageRowView, width: CGFloat, own: Bool = false) {
        let layout = RowLayout.make(row, width: width, own: own, kind: .space)
        #expect(view.rowLayout == layout)
        let pairs: [(NSView, CGRect?)] = [(view.dateLabel, layout.dateHeader), (view.avatarView, layout.avatar), (view.nameLabel, layout.name),
                                          (view.quoteView, layout.quote), (view.quoteSenderLabel, layout.quoteSender), (view.quoteTextLabel, layout.quoteText),
                                          (view.textView, layout.text), (view.repliesLink, layout.replies), (view.timeLabel, layout.time), (view.retryLink, layout.retry)]
            + zip(view.attachmentViews, layout.attachments).map { ($0, $1) } + zip(view.reactionPills, layout.reactions).map { ($0, $1) }
        for (subview, frame) in pairs {
            #expect(subview.isHidden == (frame == nil))
            if let frame { #expect(subview.frame == frame, "\(type(of: subview)) at \(subview.frame), layout \(frame)") }
        }
        #expect(view.attachmentViews.count == 2 && view.reactionPills.count == 2)
        let bubble = view.bubbleView.frame
        #expect(bubble.height == layout.bubble.height && bubble.width == layout.bubble.width + RowLayout.tailWidth)
        #expect(bubble.contains(layout.bubble))
    }

    /// The full date shows on the time only: a tooltip over the whole row got in the way of reading.
    @Test func theFullDateIsOnTheTimeNotTheRow() {
        let row = view(width: 600)
        #expect(row.toolTip == nil)
        #expect(row.timeLabel.toolTip?.isEmpty == false)
    }
    @Test func everySubviewSitsAtItsLayoutFrame() {
        expectPlaced(view(width: 640), width: 640)
        expectPlaced(view(width: 640, own: true), width: 640, own: true)
    }
    @Test func aWidthChangeMovesTheSubviews() {
        let view = view(width: 900)
        let wideText = view.textView.frame
        view.setFrameSize(NSSize(width: 460, height: RowLayout.make(row, width: 460, own: false, kind: .space).height))
        view.layoutSubtreeIfNeeded()
        expectPlaced(view, width: 460)
        #expect(view.textView.frame != wideText)
    }
    @Test func noAutoLayout() {
        let view = view(width: 640)
        #expect(view.constraints.isEmpty)
        for subview in view.subviews { #expect(subview.translatesAutoresizingMaskIntoConstraints && subview.autoresizingMask == []) }
    }
    @Test func reconfiguringReusesTheViewForAnotherRow() {
        let view = view(width: 640)
        let plain = RowLayoutTests.row("short", begins: false)
        view.configure(plain, own: true, kind: .space, meID: "me", actions: MessageRowActions())
        view.layoutSubtreeIfNeeded()
        #expect(view.attachmentViews.isEmpty && view.reactionPills.isEmpty)
        #expect(view.rowLayout == RowLayout.make(plain, width: 640, own: true, kind: .space))
        #expect(view.textView.string == "short" && view.quoteView.isHidden && view.retryLink.isHidden)
    }
    @Test func pillsAndLinksCallTheirActions() {
        var calls: [String] = []
        var actions = MessageRowActions()
        actions.react = { emoji, _ in calls.append(emoji) }
        actions.openThread = { _ in calls.append("thread") }
        actions.retry = { _ in calls.append("retry") }
        let view = view(width: 640, actions: actions)
        _ = view.reactionPills[1].accessibilityPerformPress()
        _ = view.repliesLink.accessibilityPerformPress()
        _ = view.retryLink.accessibilityPerformPress()
        #expect(calls == ["🎉", "thread", "retry"])
    }
}

@MainActor struct BubbleDrawingTests {
    @Test func aLaidOutBubbleHasItsShapeAndFill() {
        let bubble = BubbleView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        bubble.own = false; bubble.tail = true
        bubble.layout()
        let layer = try! #require(bubble.layer as? CAShapeLayer)
        #expect(layer.path != nil)
        #expect(layer.path?.boundingBox.width ?? 0 >= 190)
        #expect(layer.fillColor != nil && layer.fillColor != NSColor.black.cgColor)
        bubble.own = true
        #expect(layer.fillColor != nil && layer.fillColor != NSColor.black.cgColor)
    }
}

@MainActor struct OwnBubbleLinkTests {
    @Test func linksInOwnBubblesAreWhiteAndUnderlined() {
        let view = MessageRowView()
        let message = Message(id: "m", conversationID: "c", sender: Person(id: "me", name: "Me"), text: "see https://plane.so now")
        view.configure(TimelineRow.rows([message])[0], own: true, kind: .direct, meID: "me", actions: MessageRowActions())
        #expect(view.textView.linkTextAttributes?[.foregroundColor] as? NSColor == BubblePalette.ownInk)   // white or black, by the bubble colour
        #expect(view.textView.linkTextAttributes?[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
        view.configure(TimelineRow.rows([Message(id: "n", conversationID: "c", sender: Person(id: "a", name: "A"), text: "https://x.com")])[0],
                       own: false, kind: .direct, meID: "me", actions: MessageRowActions())
        #expect(view.textView.linkTextAttributes?[.foregroundColor] as? NSColor != .white)
    }
}

@MainActor struct MessageMenuTests {
    private func row(own: Bool) -> (MessageRowView, () -> [String]) {
        var calls: [String] = []
        let view = MessageRowView()
        let message = Message(id: "m", conversationID: "c", sender: Person(id: own ? "me" : "a", name: "X"), text: "hi")
        view.configure(TimelineRow.rows([message])[0], own: own, kind: .space, meID: "me", actions: MessageRowActions(
            react: { emoji, _ in calls.append(emoji) }, openThread: { _ in calls.append("thread") }, quote: { _ in calls.append("quote") }, retry: { _ in },
            copy: { _ in calls.append("copy") }, edit: { _ in calls.append("edit") }, delete: { _ in calls.append("delete") }))
        return (view, { calls })
    }
    @Test func theMenuStartsWithQuickReactionsThenActions() {
        let (incoming, _) = row(own: false)
        let menu = incoming.contextMenu()
        #expect(menu.items.first?.view is ReactionStrip)
        #expect(menu.items.dropFirst().filter { !$0.isSeparatorItem }.map(\.title) == ["Reply", "Reply in Thread", "Copy"])
        let (own, _) = row(own: true)
        #expect(own.contextMenu().items.dropFirst().filter { !$0.isSeparatorItem }.map(\.title) == ["Reply", "Reply in Thread", "Copy", "Edit", "Delete"])
    }
    @Test func replyQuotesAndReplyInThreadOpensTheThread() throws {
        let (view, calls) = row(own: false)
        for title in ["Reply", "Reply in Thread"] {
            let item = try #require(view.contextMenu().items.first { $0.title == title })
            item.target.map { _ = ($0 as AnyObject).perform(item.action, with: item) }
        }
        #expect(calls() == ["quote", "thread"])
    }
    @Test func theTextMenuIsTheSameMenu() throws {
        let (view, _) = row(own: true)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(try #require(view.textView.menu(for: event)).items.map(\.title) == view.contextMenu().items.map(\.title))
    }
    @Test func unsentMessagesCannotBeQuoted() {
        let view = MessageRowView()
        var message = Message(id: "m", conversationID: "c", sender: Person(id: "me", name: "X"), text: "hi"); message.delivery = .failed
        view.configure(TimelineRow.rows([message])[0], own: true, kind: .space, meID: "me", actions: MessageRowActions())
        #expect(!view.contextMenu().items.map(\.title).contains("Reply"))
    }
    @Test func aQuickReactionReacts() {
        let (view, calls) = row(own: false)
        let strip = view.contextMenu().items.first?.view as! ReactionStrip
        strip.buttons[1].performClick(nil)
        #expect(calls() == [EmojiUsage.defaults[1]])
    }
}

@MainActor struct TextMenuTests {
    @Test func rightClickingTheTextOpensTheMessageMenu() throws {
        var copied: [String] = []
        let view = MessageRowView()
        view.configure(TimelineRow.rows([Message(id: "m", conversationID: "c", sender: Person(id: "a", name: "A"), text: "hello there")])[0],
                       own: false, kind: .space, meID: "me", actions: MessageRowActions(copy: { copied.append($0.text) }))
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(view.textView.menu(for: event))
        #expect(menu.items.first?.view is ReactionStrip)
        view.textView.setSelectedRange(NSRange(location: 0, length: 5))   // with a selection, Copy copies just that
        let copy = try #require(view.textView.menu(for: event)?.items.first { $0.title == "Copy" })
        NSPasteboard.general.clearContents()
        copy.target.map { _ = ($0 as AnyObject).perform(copy.action, with: copy) }
        #expect(NSPasteboard.general.string(forType: .string) == "hello" && copied.isEmpty)
    }
}

@MainActor struct SwipeRevealTests {
    @Test func swipingSlidesTheRowAndRevealsTheReplyArrow() {
        let view = MessageRowView(frame: NSRect(x: 0, y: 0, width: 600, height: 60))
        view.configure(TimelineRow.rows([Message(id: "m", conversationID: "c", sender: Person(id: "a", name: "A"), text: "hi")])[0],
                       own: false, kind: .space, meID: "me", actions: MessageRowActions())
        view.layoutSubtreeIfNeeded()
        #expect(view.replyArrow.alphaValue == 0)
        view.setSwipe(offset: -60, stage: nil)
        #expect(view.bounds.origin.x == 60)                      // content slides left with the fingers
        #expect(view.replyArrow.alphaValue > 0 && view.replyArrow.alphaValue < 1)
        #expect(view.visibleRect.contains(view.replyArrow.frame))  // the arrow sits in the revealed strip
        #expect(view.replyArrow.image?.accessibilityDescription == "Reply")
        view.setSwipe(offset: -120, stage: .quote)
        #expect(view.replyArrow.alphaValue == 1 && view.replyArrow.image?.accessibilityDescription == "Reply")
        view.setSwipe(offset: -200, stage: .thread)                // further: the icon becomes the thread's
        #expect(view.replyArrow.alphaValue == 1 && view.replyArrow.image?.accessibilityDescription == "Reply in Thread")
        #expect(view.visibleRect.contains(view.replyArrow.frame))
        view.setSwipe(offset: -150, stage: .quote)                 // and back
        #expect(view.replyArrow.image?.accessibilityDescription == "Reply")
        view.setSwipe(offset: 0, stage: nil)
        #expect(view.bounds.origin.x == 0 && view.replyArrow.alphaValue == 0)
    }
}

@MainActor struct WritingToolsTests {
    /// Seen live: macOS drew a Siri / Writing Tools badge at the corner of message bubbles. Messages are read-only.
    @Test func messageTextOffersNoWritingTools() {
        let view = MessageRowView()
        if #available(macOS 15.2, *) { #expect(view.textView.writingToolsBehavior == .none) }
    }
}

@MainActor struct ReactionStripTests {
    /// The More button's color is baked into its image, not applied as a tint: on macOS 15 a menu item's view
    /// drew the tinted template symbol blank.
    @Test func moreButtonShowsAnUntintedSymbol() throws {
        let strip = ReactionStrip(emoji: ["👍"], react: { _ in }, more: {})
        let image = try #require(strip.moreButton.image)
        #expect(!image.isTemplate)
        #expect(strip.moreButton.contentTintColor == nil)
        #expect(image.size.width > 0)
    }
}
