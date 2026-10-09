import AppKit
import Testing
@testable import Parley

/// A workspace's own emoji, as Google Chat sends it.
private func parrot(deleted: Bool = false) -> Dynamite_CustomEmoji {
    .with {
        $0.uuid = "uuid-1"; $0.shortcode = "parrot"; $0.state = deleted ? .deleted : .enabled
        $0.creatorUserID.id = "u1"; $0.ownerCustomerID.customerID = "C0"; $0.blobID = "blob"
        $0.readToken = "token+1"; $0.createTimeMicros = 5; $0.contentType = "image/png"
    }
}
private func emojiAnnotation(_ emoji: Dynamite_CustomEmoji, at start: Int32) -> Dynamite_Annotation {
    .with { $0.type = .customEmoji; $0.startIndex = start; $0.length = 1; $0.customEmojiMetadata.customEmoji = emoji }
}

struct CustomEmojiMapperTests {
    @Test func annotationBecomesAStyleOnItsReplacementCharacter() throws {
        let rich = DynamiteMapper.richText("so good \u{FFFD}!", [emojiAnnotation(parrot(), at: 8)])
        #expect(rich.text == "so good \u{FFFD}!")
        let range = try #require(rich.formatting.first)
        #expect(range.start == 8 && range.length == 1)
        guard case .customEmoji(let emoji) = range.style else { Issue.record("not a custom emoji"); return }
        #expect(emoji.id == "uuid-1" && emoji.shortcode == "parrot" && !emoji.deleted)
        #expect(emoji.imageURL?.absoluteString == "https://chat.google.com/api/get_custom_emoji_image?custom_emoji_read_token=token%2B1&rwa=true")
        #expect(try Dynamite_CustomEmoji(serializedBytes: emoji.payload) == parrot())
        #expect(TextStyleRange.plain(rich.text, rich.formatting) == "so good :parrot:!")
    }
    @Test func deletedEmojiHasNoImage() throws {
        let rich = DynamiteMapper.richText("\u{FFFD}", [emojiAnnotation(parrot(deleted: true), at: 0)])
        guard case .customEmoji(let emoji) = try #require(rich.formatting.first).style else { Issue.record("not a custom emoji"); return }
        #expect(emoji.deleted && emoji.imageURL == nil && emoji.image == nil)
    }
    @Test func customReactionsKeepTheWholeEmoji() throws {
        let reactions = DynamiteMapper.reactions([
            .with { $0.emoji.customEmoji = parrot(); $0.count = 2; $0.currentUserReacted = true },
            .with { $0.emoji.unicode = "👍"; $0.count = 1 },
        ], selfID: "me")
        #expect(reactions.map(\.emoji) == [":parrot:", "👍"])
        #expect(reactions[0].people.count == 2 && reactions[0].people.contains("me") && reactions[1].custom == nil)
        let custom = try #require(reactions[0].custom)
        #expect(DynamiteMapper.emoji(custom.text, custom: custom).customEmoji == parrot())
        #expect(DynamiteMapper.emoji("👍", custom: nil).unicode == "👍")
    }
    @Test func launchCachesFromBeforeCustomEmojiStillDecode() throws {
        let old = #"{"emoji":"👍","people":["a"]}"#
        #expect(try JSONDecoder().decode(Reaction.self, from: Data(old.utf8)) == Reaction(emoji: "👍", people: ["a"]))
        let emoji = try #require(DynamiteMapper.customEmoji(parrot()))
        let message = Message(id: "m", conversationID: "c", sender: Person(id: "u", name: "U"), text: "\u{FFFD}",
                              reactions: [Reaction(emoji: emoji.text, people: ["a"], custom: emoji)],
                              formatting: [TextStyleRange(style: .customEmoji(emoji), start: 0, length: 1)])
        #expect(try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message)) == message)
    }
}

@MainActor struct CustomEmojiRenderingTests {
    private let emoji = CustomEmoji(id: "e", shortcode: "parrot", imageURL: URL(string: "https://example.invalid/parrot"))
    @Test func styledTextPutsAnImageAttachmentAtTheEmoji() throws {
        let styled = MessageTextStyle.styled("hi \u{FFFD} there", [TextStyleRange(style: .customEmoji(emoji), start: 3, length: 1)], own: false)
        #expect(styled.length == 10)
        let attachment = try #require(styled.attribute(.attachment, at: 3, effectiveRange: nil) as? NSTextAttachment)
        let font = try #require(styled.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)
        #expect(attachment.bounds.height == ceil(font.ascender - font.descender) && attachment.bounds.width == attachment.bounds.height)
        #expect(!styled.string.contains("\u{FFFD}"))
    }
    @Test func deletedEmojiShowsItsShortcode() {
        var deleted = emoji; deleted.deleted = true; deleted.imageURL = nil
        let styled = MessageTextStyle.styled("a\u{FFFD}b", [TextStyleRange(style: .customEmoji(deleted), start: 1, length: 1), TextStyleRange(style: .bold, start: 2, length: 1)], own: false)
        #expect(styled.string == "a:parrot:b")
        let font = styled.attribute(.font, at: 9, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)   // styles after it keep their place
    }
    @Test func customReactionPillShowsTheImage() {
        let pill = RowLayout.pillText(Reaction(emoji: emoji.text, people: ["a", "b"], custom: emoji))
        #expect(pill.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment)
        #expect(pill.string.hasSuffix(" 2") && !pill.string.contains("parrot"))
    }
}

extension AuthTests {
    @Test func clickingACustomReactionSendsTheWholeEmojiBack() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_UpdateReactionResponse())])
        var head = Self.message("h1", topic: "t1", at: 1)
        head.reactions = [.with { $0.emoji.customEmoji = parrot(); $0.count = 1 }]
        await backend.handle(Self.pushed(.messagePosted, head))
        let reaction = try #require(DynamiteMapper.reactions([.with { $0.emoji.customEmoji = parrot(); $0.count = 1 }], selfID: "me").first)
        try await backend.setReaction(reaction.emoji, custom: reaction.custom, on: "space/x/t1/h1", present: true)
        let sent = try Dynamite_UpdateReactionRequest(serializedBytes: Self.body(try #require(exchange.requests.last { $0.url?.path == "/api/update_reaction" })))
        #expect(sent.emoji.customEmoji == parrot() && sent.option == .add)
        let after = Self.upserts(await Self.drain(backend)).last?.reactions
        #expect(after?.count == 1 && after?[0].people.contains("me") == true && after?[0].custom?.id == "uuid-1")
    }
}

/// A quote shows its custom emoji as pictures, as the message itself does; places that show plain text keep ":shortcode:".
struct QuotedCustomEmojiTests {
    private let emoji = CustomEmoji(id: "e", shortcode: "masabito", imageURL: URL(string: "https://example.invalid/masabito"))
    @Test func aQuoteKeepsWhereItsEmojiAre() throws {
        let proto = Dynamite_Message.with { m in
            m.id.messageID = "m2"; m.id.parentID.topicID.topicID = "m2"; m.creator.userID.id = "u1"; m.textBody = "pk"
            m.quotedMessageMetadata = .with { q in
                q.messageID.messageID = "m1"; q.messageID.parentID.topicID.topicID = "m1"; q.creator.userID.id = "u2"
                q.textBody = "dije a \u{FFFD}que"
                q.annotations = [emojiAnnotation(parrot(), at: 7)]
            }
        }
        let quote = try #require(DynamiteMapper.message(proto, in: "space/s", selfID: "me", people: [:])?.quote)
        #expect(quote.text == "dije a :parrot:que")   // notifications and Home read this
        let placed = try #require(quote.emoji?.first)
        guard case .customEmoji(let shown) = placed.style else { Issue.record("not an emoji"); return }
        #expect(quote.emoji?.count == 1 && shown.shortcode == "parrot" && placed.start == 7 && placed.length == 8)
    }
    @Test func theTimelinesQuoteDrawsTheEmojiPicture() {   // the row's quote label, not the message text
        let quote = QuotedMessage(sender: "Dave", text: "dije a :masabito:que", emoji: [TextStyleRange(style: .customEmoji(emoji), start: 7, length: 10)])
        let body = RowLayout.quoteBodyText(quote).string
        #expect(body == "dije a \u{FFFC}que")
    }
    @Test func theQuoteBlockDrawsTheEmojiPicture() {
        let quote = QuotedMessage(sender: "Dave", text: "dije a :masabito:que", emoji: [TextStyleRange(style: .customEmoji(emoji), start: 7, length: 10)])
        let styled = MessageTextStyle.styled("pk", [], quote, own: false).string
        #expect(!styled.contains(":masabito:") && styled.contains("\u{FFFC}"))   // an attachment, not the shortcode
    }
}
