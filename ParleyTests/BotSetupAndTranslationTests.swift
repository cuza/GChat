import AppKit
import Foundation
import Testing
@testable import Parley

/// An app that needs setting up, told only to me under my own message; and a message Google translated for me.
struct BotSetupAndTranslationTests {
    private func message(text: String = "See https://example.com/x", _ configure: (inout Dynamite_Message) -> Void) -> Dynamite_Message {
        .with { m in m.id.messageID = "m1"; m.id.parentID.topicID.topicID = "t1"; m.creator.userID.id = "me"; m.textBody = text
            m.messageType = .userMessage; configure(&m) }
    }
    private func setup(_ action: Int32, url: String = "https://example.com/setup") -> Dynamite_Message {
        message { $0.botResponses = [.with { r in r.type = 2; r.requiredAction = action; r.setupURL = url; r.bot.userID.id = "bot1" }] }
    }
    private func card(_ proto: Dynamite_Message, people: [String: Person] = [:]) throws -> (Message, [Card.Item]) {
        let shown = try #require(DynamiteMapper.message(proto, in: "space/s", selfID: "me", people: people))
        return (shown, shown.attachments.compactMap(\.card).flatMap { $0.sections.flatMap { $0 } })
    }
    @Test func anAppThatNeedsSigningInSaysSoUnderMyMessage() throws {
        let icon = URL(string: "https://example.com/app.png")!
        let (shown, items) = try card(setup(2), people: ["bot1": Person(id: "bot1", name: "Example", avatarURL: icon)])
        #expect(shown.text == "See https://example.com/x")
        #expect(items.first == .text("Only visible to you", [TextStyleRange(style: .color(Card.secondaryText), start: 0, length: 19)]))
        #expect(items.contains { if case .row(icon, _, _, "Example", _, _) = $0 { true } else { false } })
        #expect(items.contains(.text("Example requires authentication", [])))
        #expect(items.contains(.links([Card.Link(title: "Sign in", url: URL(string: "https://example.com/setup")!)])))
        #expect(DynamiteMapper.undrawn(setup(2), selfID: "me").isEmpty)
    }
    @Test func configureAndNotRespondingFollowTheRequiredAction() throws {
        let (_, configure) = try card(setup(1))
        #expect(configure.contains(.text("App requires configuration", [])))   // not looked up yet: "App"
        #expect(configure.contains(.links([Card.Link(title: "Configure", url: URL(string: "https://example.com/setup")!)])))
        let (_, silent) = try card(setup(0))
        #expect(silent.contains(.text("App not responding", [])) && !silent.contains { if case .links = $0 { true } else { false } })
        let (_, insecure) = try card(setup(2, url: "http://example.com/setup"))
        #expect(!insecure.contains { if case .links = $0 { true } else { false } })   // https only
        #expect(DynamiteMapper.cardAppIDs(setup(2)).contains("bot1"))   // looked up as a bot
    }
    @Test func withoutTextTheCouldNotRespondRowStays() throws {
        var empty = setup(2); empty.textBody = ""
        #expect(try card(empty).0.text.hasSuffix("couldn’t respond"))
    }
    @Test func aTranslatedMessageShowsTheTranslationAndCanShowTheOriginal() throws {
        let proto = message(text: "Hola, ¿cómo estás?") { $0.translation = .with { t in
            t.text = "Hello, how are you?"; t.sourceLanguage = "es"; t.targetLanguage = "en"
            t.annotations = [.with { $0.type = .formatData; $0.startIndex = 0; $0.length = 5; $0.formatMetadata.formatType = .bold }] } }
        let shown = try #require(DynamiteMapper.message(proto, in: "space/s", selfID: "me", people: [:]))
        #expect(shown.text == "Hola, ¿cómo estás?")   // the original stays the message's text (notifications, Home, quotes)
        #expect(shown.translation?.text == "Hello, how are you?" && shown.translation?.from == "es")
        #expect(shown.translation?.formatting.contains(TextStyleRange(style: .bold, start: 0, length: 5)) == true)
        #expect(DynamiteMapper.undrawn(proto, selfID: "me").isEmpty)
        // The timeline shows the translation, and the original once opened.
        let translated = TimelineRow.rows([shown])[0], original = TimelineRow.rows([shown], transcripts: [shown.id])[0]
        #expect(translated.message.text == "Hello, how are you?" && original.message.text == "Hola, ¿cómo estás?")
        let label = RowLayout.translationLabel(shown.translation!, showingOriginal: false)
        #expect(label == "View original (\(Locale.current.localizedString(forLanguageCode: "es")!))")
        #expect(RowLayout.translationLabel(shown.translation!, showingOriginal: true) == "Show translation")
        let layout = RowLayout.make(translated, width: 600, own: false, kind: .space)
        #expect(layout.translation != nil && RowLayout.make(RowLayoutTests.row("hi"), width: 600, own: false, kind: .space).translation == nil)
        // Under the bubble, at its edge, small, after the translate icon, as Google Chat draws it; the row makes room.
        let toggle = try #require(layout.translation)
        #expect(toggle.minY >= layout.bubble.maxY && toggle.minX == layout.bubble.minX && layout.height >= toggle.maxY)
        let text = RowLayout.translationText(shown.translation!, showingOriginal: false)
        #expect(text.containsAttachments(in: NSRange(location: 0, length: text.length)) && text.string.hasSuffix(label))
        let font = text.attribute(.font, at: text.length - 1, effectiveRange: nil) as? NSFont
        #expect((font?.pointSize ?? 99) <= 11)
        let plain = RowLayout.make(TimelineRow(message: { var m = shown; m.translation = nil; return m }(), begins: true, ends: true, newDay: false), width: 600, own: false, kind: .space)
        #expect(layout.bubble.height == plain.bubble.height)   // nothing added inside the bubble
    }
}
