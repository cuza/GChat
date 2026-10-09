import AppKit
import Testing
@testable import Parley

/// A Chat link typed or pasted in the composer offers to become its conversation's chip, as Google Chat's web composer
/// does ("Tab to replace with Town Hall"); the chip goes out as a GROUP annotation over the conversation's name.
@MainActor struct SpaceChipTests {
    let hall = Conversation(id: "space/AAQA1-876WI", name: "Town Hall", kind: .space, members: [])
    let link = "https://chat.google.com/room/AAQA1-876WI/emcC87MYZLM/emcC87MYZLM?cls=10"

    @Test func aLinkBeforeTheCaretToAKnownConversationIsOffered() {
        #expect(MentionQuery.chatLink(in: "see " + link, caret: 4 + link.utf16.count, among: [hall])?.chip == hall)
        #expect(MentionQuery.chatLink(in: "see " + link, caret: 4 + link.utf16.count, among: [hall])?.range == NSRange(location: 4, length: link.utf16.count))
        #expect(MentionQuery.chatLink(in: link + " ", caret: link.utf16.count + 1, among: [hall]) == nil)        // the caret moved on
        #expect(MentionQuery.chatLink(in: "https://chat.google.com/room/OTHER", caret: 34, among: [hall]) == nil)   // not one of mine
        #expect(MentionQuery.chatLink(in: "https://example.com/room/AAQA1-876WI", caret: 36, among: [hall]) == nil)
        let dm = Conversation(id: "dm/abc", name: "Alex", kind: .direct, members: [])   // Google Chat makes no DM chips
        #expect(MentionQuery.chatLink(in: "https://chat.google.com/dm/abc", caret: 30, among: [dm]) == nil)
    }
    @Test func tabReplacesTheLinkWithTheChipAndReturnDoesNot() throws {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.chipConversations = [hall]
        view.load("", [])
        view.insertText("see " + link, replacementRange: view.selectedRange())
        #expect(view.mentionMatches == [.space(hall)])
        let tab = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        view.keyDown(with: tab)
        #expect(view.string == "see Town Hall")
        #expect(view.formatting == [TextStyleRange(style: .chip(hall.id, link: URL(string: link)), start: 4, length: 9)])
        #expect(view.mentionMatches.isEmpty)

        var sent = false
        let other = ComposerTextView(usingTextLayoutManager: false)
        other.chipConversations = [hall]; other.send = { sent = true }
        other.load("", [])
        other.insertText(link, replacementRange: other.selectedRange())
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                  characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        other.keyDown(with: enter)
        #expect(sent)
        #expect(other.string == link)   // Return sends the link as typed
    }
    @Test func editingTheChipsTextMakesItPlainText() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.chipConversations = [hall]
        view.load("", [])
        view.insertText(link, replacementRange: view.selectedRange())
        view.insert(.space(hall), replacing: NSRange(location: 0, length: link.utf16.count))
        view.setSelectedRange(NSRange(location: 4, length: 0))
        view.insertText("x", replacementRange: view.selectedRange())
        #expect(view.formatting.isEmpty)
    }
    @Test func aConversationParleyCantOpenIsNamedAsWebNamesIt() throws {
        #expect(try #require(ChatLink(URL(string: "https://chat.google.com/room/AAQA1-876WI")!)).restrictedTitle == "Restricted space")
        #expect(try #require(ChatLink(URL(string: "https://chat.google.com/dm/abc")!)).restrictedTitle == "Restricted conversation")
        #expect(try #require(ChatLink(URL(string: "https://chat.google.com/app/chat/abc")!)).restrictedTitle == "Restricted conversation")   // space or DM
    }
    /// A received chip shows as Google Chat draws it: a rounded pill with the space's emoji and its name, opening the space.
    @Test func aReceivedChipIsAPillWithItsEmoji() throws {
        let chip = Dynamite_Annotation.with { a in
            a.type = .group; a.startIndex = 4; a.length = 9
            a.groupMetadata = .with { $0.groupID.spaceID.spaceID = "AAQA1-876WI"; $0.avatarInfo.emoji.unicode = "🏰" }
        }
        let shown = DynamiteMapper.richText("see Town Hall", [chip])
        #expect(shown.formatting == [TextStyleRange(style: .chip("space/AAQA1-876WI", emoji: "🏰"), start: 4, length: 9)])
        let styled = MessageTextStyle.styled(shown.text, shown.formatting, own: false)
        #expect(styled.string.contains("🏰"))
        let at = (styled.string as NSString).range(of: "Town").location
        #expect(styled.attribute(MessageTextStyle.chipKey, at: at, effectiveRange: nil) as? URL == ChatLink.url("space/AAQA1-876WI"))
        #expect(styled.attribute(.backgroundColor, at: at, effectiveRange: nil) != nil && styled.attribute(.link, at: at, effectiveRange: nil) == nil)
    }
    /// Editing a message with a chip sends the chip back once: as the message's own annotation.
    @Test func editingSendsAChipOnce() {
        let kept = Dynamite_Annotation.with { a in a.type = .group; a.startIndex = 0; a.length = 9; a.groupMetadata.groupID.spaceID.spaceID = "AAQA1-876WI" }
        let formatting = [TextStyleRange(style: .chip("space/AAQA1-876WI", emoji: "🏰"), start: 0, length: 9), TextStyleRange(style: .bold, start: 0, length: 2)]
        #expect(DynamiteBackend.sendable(formatting, besides: [kept]) == [TextStyleRange(style: .bold, start: 0, length: 2)])
    }
    /// As Google Chat's composer sends a chip made from a pasted link: inline (no chip card), opening the link, with the
    /// space's emoji and the linked message, plus the message-level note that it needs group smart chips (6).
    @Test func aChipIsSentAsGoogleChatsComposerSendsIt() throws {
        let link = URL(string: "https://chat.google.com/room/AAQA1-876WI/0RU6HU5JKRo/0RU6HU5JKRo?cls=10")!
        let sent = DynamiteMapper.annotations([TextStyleRange(style: .chip("space/AAQA1-876WI", emoji: "🏰", link: link), start: 4, length: 9)])
        #expect(sent.map(\.type) == [.group, .requiredMessageFeaturesMetadata])
        let chip = sent[0], features = sent[1]
        #expect(chip.startIndex == 4 && chip.length == 9 && chip.chipRenderType == .doNotRender && chip.inlineRenderFormat == 1)
        #expect(chip.interactionData.url.url == link.absoluteString)
        #expect(chip.groupMetadata.groupID.spaceID.spaceID == "AAQA1-876WI" && chip.groupMetadata.avatarInfo.emoji.unicode == "🏰")
        #expect(chip.groupMetadata.messageID.messageID == "0RU6HU5JKRo" && chip.groupMetadata.messageID.parentID.topicID.topicID == "0RU6HU5JKRo")
        #expect(features.chipRenderType == .render && features.requiredMessageFeaturesMetadata.requiredFeatures == [6])
        // Shown in the timeline (a local echo) as a chip, as a received one is.
        let styled = MessageTextStyle.styled("see Town Hall", [TextStyleRange(style: .chip("space/AAQA1-876WI"), start: 4, length: 9)], own: true)
        #expect(styled.attribute(MessageTextStyle.chipKey, at: 6, effectiveRange: nil) as? URL == ChatLink.url("space/AAQA1-876WI"))
    }
    @Test func tabKeepsThePastedLinkAndTheSpacesEmoji() throws {
        var hall = self.hall; hall.emoji = "🏰"
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.chipConversations = [hall]
        view.load("", [])
        view.insertText(link, replacementRange: view.selectedRange())
        view.insert(.space(hall), replacing: NSRange(location: 0, length: link.utf16.count))
        #expect(view.formatting == [TextStyleRange(style: .chip(hall.id, emoji: "🏰", link: URL(string: link)), start: 0, length: 9)])
    }
}
