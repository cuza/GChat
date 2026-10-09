import AppKit
import Testing
@testable import Parley

@MainActor struct JumboEmojiTests {
    static func message(_ text: String, configure: (inout Message) -> Void = { _ in }) -> Message {
        var message = Message(id: "m", conversationID: "c", sender: Person(id: "a", name: "Alex"), text: text, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        configure(&message)
        return message
    }
    static let parrot = CustomEmoji(id: "e", shortcode: "parrot", imageURL: URL(string: "https://example.com/p.png"))

    @Test func oneToThreeEmojiAloneAreShownLarge() {
        #expect(Self.message("😅").jumboEmoji == 1)
        #expect(Self.message(" 😅 😅 ").jumboEmoji == 2)
        #expect(Self.message("❤️👍🏽🇨🇺").jumboEmoji == 3)
        #expect(Self.message("👨‍👩‍👧").jumboEmoji == 1)
        #expect(Self.message("\u{FFFD}") { $0.formatting = [TextStyleRange(style: .customEmoji(Self.parrot), start: 0, length: 1)] }.jumboEmoji == 1)
        #expect(Self.message("😅\u{FFFD}") { $0.formatting = [TextStyleRange(style: .customEmoji(Self.parrot), start: 2, length: 1)] }.jumboEmoji == 2)
    }
    @Test func anythingElseKeepsTheBubble() {
        for text in ["😅😅😅😅", "hi 😅", "1", "#", "", "\u{FFFD}"] { #expect(Self.message(text).jumboEmoji == nil, "\(text)") }
        #expect(Self.message("😅") { $0.formatting = [TextStyleRange(style: .bold, start: 0, length: 2)] }.jumboEmoji == nil)
        #expect(Self.message("😅") { $0.attachments = [Attachment(name: "a.png", kind: .image)] }.jumboEmoji == nil)
        #expect(Self.message("😅") { $0.quote = QuotedMessage(sender: "Sam", text: "hi") }.jumboEmoji == nil)
    }
    @Test func largeEmojiHaveNoBubbleAndBigText() throws {
        let row = TimelineRow.rows([Self.message("😅")])[0], plain = TimelineRow.rows([Self.message("ok")])[0]
        let layout = RowLayout.make(row, width: 600, own: true, kind: .direct)
        #expect(layout.bare && !RowLayout.make(plain, width: 600, own: true, kind: .direct).bare)
        #expect(try #require(layout.text).height > 50)
        let view = MessageRowView()
        view.configure(row, own: true, kind: .direct, meID: "a", layout: layout, actions: MessageRowActions())
        view.frame = NSRect(x: 0, y: 0, width: 600, height: layout.height); view.layoutSubtreeIfNeeded()
        #expect(view.bubbleView.isHidden && view.timeLabel.background != nil)
    }
}

@MainActor struct EmojiHoverCardTests {
    private func textView(_ text: String, _ formatting: [TextStyleRange] = []) -> MessageTextView {
        var message = JumboEmojiTests.message(text); message.formatting = formatting
        let view = MessageRowView()
        view.configure(TimelineRow.rows([message])[0], own: false, kind: .direct, meID: "me", actions: MessageRowActions())
        return view.textView
    }
    @Test func anEmojiInTextGetsTheReactionCardWithItsName() throws {
        let view = textView("Sorry 🙏🏽 ok")
        let card = try #require(view.emojiCard(at: 7))   // inside the emoji's UTF-16 range
        #expect(card.range == NSRange(location: 6, length: 4) && card.content.reaction.emoji == "🙏🏽")
        #expect(card.content.names == ":person-with-folded-hands:")
        #expect(view.emojiCard(at: 0) == nil && view.emojiCard(at: 11) == nil)   // letters
    }
    @Test func aCustomEmojiShowsItsPictureAndShortcode() throws {
        let view = textView("hi \u{FFFD}", [TextStyleRange(style: .customEmoji(JumboEmojiTests.parrot), start: 3, length: 1)])
        let card = try #require(view.emojiCard(at: 3))
        #expect(card.content.reaction.custom == JumboEmojiTests.parrot && card.content.names.isEmpty)
    }
}
