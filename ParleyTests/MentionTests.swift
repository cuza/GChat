import AppKit
import Foundation
import SwiftProtobuf
import Testing
@testable import Parley

@MainActor struct MentionComposerTests {
    let maria = Person(id: "maria", name: "Maria Chen")
    let alex = Person(id: "alex", name: "Alex Rivera")
    let mark = Person(id: "mark", name: "Mark Twain")
    let jose = Person(id: "jose", name: "José Núñez")

    @Test func anAtAfterSpaceOrAtTheStartStartsAMention() {
        #expect(MentionQuery.find(in: "hi @ma", caret: 6) == MentionQuery(range: NSRange(location: 3, length: 3), text: "ma"))
        #expect(MentionQuery.find(in: "@", caret: 1) == MentionQuery(range: NSRange(location: 0, length: 1), text: ""))
        #expect(MentionQuery.find(in: "x\n@Maria C", caret: 10)?.text == "Maria C")   // names have spaces
        #expect(MentionQuery.find(in: "hi @ma there", caret: 6)?.text == "ma")       // only what is before the caret
    }
    @Test func anAtInsideAWordOrAcrossALineIsNotAMention() {
        #expect(MentionQuery.find(in: "mail@ma", caret: 7) == nil)
        #expect(MentionQuery.find(in: "@ma\nx", caret: 5) == nil)
        #expect(MentionQuery.find(in: "@ ma", caret: 4) == nil)   // a space right after @ ends it
        #expect(MentionQuery.find(in: "hi", caret: 2) == nil)
    }
    @Test func filteringMatchesWordPrefixesIgnoringCaseAndAccents() {
        let people = [maria, alex, mark, jose]
        #expect(MentionQuery.filter(people, by: "").map(\.id) == ["alex", "jose", "maria", "mark"])
        #expect(MentionQuery.filter(people, by: "MA").map(\.id) == ["maria", "mark"])
        #expect(MentionQuery.filter(people, by: "riv").map(\.id) == ["alex"])
        #expect(MentionQuery.filter(people, by: "jose nu").map(\.id) == ["jose"])
        #expect(MentionQuery.filter(people, by: "zz").isEmpty)
    }
    @Test func typingAnAtShowsTheQuery() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.load("hi ", [])
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.insertText("@ma", replacementRange: view.selectedRange())
        #expect(view.mentionQuery?.text == "ma")
    }
    @Test func pickingInsertsAStyledTokenAndASpace() throws {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.load("hi @ma", [])
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.insertMention(maria, replacing: NSRange(location: 3, length: 3))
        #expect(view.string == "hi @Maria Chen ")
        #expect(view.formatting == [TextStyleRange(style: .mention(userID: "maria"), start: 3, length: 11)])
        #expect(view.selectedRange() == NSRange(location: 15, length: 0))
        #expect(view.mentionQuery == nil)
        let color = try #require(view.textStorage?.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor)
        #expect(color == .controlAccentColor)
    }
    @Test func textTypedAfterATokenIsNotPartOfIt() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.load("@Maria Chen", [TextStyleRange(style: .mention(userID: "maria"), start: 0, length: 11)])
        view.setSelectedRange(NSRange(location: 11, length: 0))
        view.insertText("!", replacementRange: view.selectedRange())
        #expect(view.formatting == [TextStyleRange(style: .mention(userID: "maria"), start: 0, length: 11)])
    }
    @Test func backspaceDeletesTheWholeToken() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.load("hi @Maria Chen ok", [TextStyleRange(style: .mention(userID: "maria"), start: 3, length: 11)])
        view.setSelectedRange(NSRange(location: 14, length: 0))
        view.deleteBackward(nil)
        #expect(view.string == "hi  ok")
        #expect(view.formatting.isEmpty)
    }
    @Test func editingInsideATokenTurnsItBackIntoText() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.load("@Maria Chen", [TextStyleRange(style: .mention(userID: "maria"), start: 0, length: 11)])
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.insertText("x", replacementRange: view.selectedRange())
        #expect(view.string == "@Maxria Chen")
        #expect(view.formatting.isEmpty)
    }
    @Test func loadingDropsMentionsWithoutAUser() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.load("@Old", [TextStyleRange(style: .mention(userID: nil), start: 0, length: 4)])
        #expect(view.formatting.isEmpty)
    }
}

@MainActor struct MentionMembersTests {
    @Test func candidatesComeFromTheBackendOnceWithoutMe() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        await store.loadMembers("design")
        await store.loadMembers("design")
        #expect(await fake.memberRequests == ["design"])
        #expect(store.mentionCandidates("design").map(\.id) == ["maria", "alex"])
    }
    @Test func candidatesFallBackToTheConversationMembers() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        #expect(store.mentionCandidates("maria").map(\.id) == ["maria"])
    }
}

struct MentionAnnotationTests {
    @Test func aMentionBecomesAUserMentionAnnotationAsGoogleChatBuildsIt() throws {
        let annotations = DynamiteMapper.annotations([TextStyleRange(style: .mention(userID: "u2"), start: 3, length: 6),
                                                      TextStyleRange(style: .mention(userID: nil), start: 10, length: 2)])
        #expect(annotations.count == 1)
        let bytes = try #require(annotations.first).serializedBytes() as [UInt8]
        // type 6 · start 3 · length 6 · user_mention_metadata { id {u2, HUMAN}, MENTION, invitee_info { user_id {u2, HUMAN} } }
        #expect(bytes == [0x08, 0x06, 0x10, 0x03, 0x18, 0x06, 0x2a, 0x14,
                          0x0a, 0x06, 0x0a, 0x02, 0x75, 0x32, 0x10, 0x00,
                          0x10, 0x03,
                          0x1a, 0x08, 0x0a, 0x06, 0x0a, 0x02, 0x75, 0x32, 0x10, 0x00])
    }
    @Test func anAtAllMentionIsSentAsMentionAllWithoutAUser() throws {
        let annotations = DynamiteMapper.annotations([TextStyleRange(style: .mention(userID: TextStyleRange.everyone), start: 0, length: 4)])
        let annotation = try #require(annotations.first)
        #expect(annotations.count == 1 && annotation.type == .userMention && annotation.startIndex == 0 && annotation.length == 4)
        #expect(annotation.userMentionMetadata.type == .mentionAll && !annotation.userMentionMetadata.hasID && !annotation.userMentionMetadata.hasInviteeInfo)
        // and it reads back as @all
        #expect(DynamiteMapper.richText("@all hi", annotations).formatting == [TextStyleRange(style: .mention(userID: TextStyleRange.everyone), start: 0, length: 4)])
    }
}

/// Network-stubbed: joins the serialized AuthTests suite (the stub registry is global).
extension AuthTests {
    @Test func mentionsAreSentAsUserMentionAnnotations() async throws {
        let topic = try Self.proto(Dynamite_CreateTopicResponse.with { $0.topic.replies = [Self.message("m9", topic: "m9", at: 5, by: "me")] })
        let (backend, exchange) = try await Self.connected([topic])
        let mention = [TextStyleRange(style: .mention(userID: "u1"), start: 3, length: 6)]
        _ = try await backend.send(MessageDraft(text: "hi @Maria ", localID: "local-1", formatting: mention), to: "dm/a", thread: nil)
        let request = try Dynamite_CreateTopicRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(request.messageInfo.acceptFormatAnnotations)
        let annotation = try #require(request.annotations.first)
        #expect(annotation.type == .userMention && annotation.startIndex == 3 && annotation.length == 6)
        #expect(annotation.userMentionMetadata.id.id == "u1" && annotation.userMentionMetadata.type == .mention)
    }
    @Test func editingAMessageKeepsItsAtAllMention() async throws {
        var edited = Self.message("h1", topic: "t1", at: 1, by: "me"); edited.textBody = "@all now"
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_EditMessageResponse.with { $0.message = edited })])
        try await backend.edit("space/x/t1/h1", text: "@all now", formatting: [TextStyleRange(style: .mention(userID: TextStyleRange.everyone), start: 0, length: 4)])
        let request = try Dynamite_EditMessageRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        let annotation = try #require(request.annotations.first)
        #expect(request.messageInfo.acceptFormatAnnotations)
        #expect(annotation.type == .userMention && annotation.length == 4 && annotation.userMentionMetadata.type == .mentionAll)
    }
    @Test func membersAreListedForTheGroup() async throws {
        let page1 = try Self.proto(Dynamite_ListMembersResponse.with {
            $0.members = [("u1", "Maria"), ("u3", "Sam")].map { id, name in .with { $0.user.userID.id = id; $0.user.name = name } }
            $0.nextPageToken = "next"
        })
        let page2 = try Self.proto(Dynamite_ListMembersResponse.with { $0.members = [.with { $0.user.userID.id = "u4"; $0.user.name = "Kim" }] })
        let (backend, exchange) = try await Self.connected([page1, page2])
        let people = try await backend.members(of: "space/x")
        #expect(people.map(\.id) == ["u1", "u3", "u4"] && people.map(\.name) == ["Maria", "Sam", "Kim"])
        let requests = try exchange.requests.filter { $0.url?.path == "/api/list_members" }.map { try Dynamite_ListMembersRequest(serializedBytes: Self.body($0)) }
        #expect(requests.count == 2)
        #expect(requests[0].groupID.spaceID.spaceID == "x" && requests[0].membershipFilter == 4 && requests[0].memberTypes == [1, 5])
        #expect(requests[0].pageSize == 100 && requests[0].flag8 && !requests[0].hasPageToken && requests[0].hasRequestHeader)
        #expect(requests[1].pageToken == "next")
    }
}

@MainActor struct MentionCardTests {
    static let text = "hi @Maria Chen and @all"
    static let formatting = [TextStyleRange(style: .mention(userID: "maria"), start: 3, length: 11),
                             TextStyleRange(style: .mention(userID: TextStyleRange.everyone), start: 19, length: 4)]

    @Test func onlyAPersonMentionCarriesTheirID() {
        let styled = MessageTextStyle.styled(Self.text, Self.formatting, own: false)
        var range = NSRange()
        #expect(styled.attribute(MessageTextStyle.mentionKey, at: 3, effectiveRange: &range) as? String == "maria")
        #expect(range == NSRange(location: 3, length: 11))
        #expect(styled.attribute(MessageTextStyle.mentionKey, at: 20, effectiveRange: nil) == nil)
    }
    @Test func thePersonComesFromMembersOrSenders() async {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        #expect(store.person("alex", in: "design")?.name == "Alex Rivera")
        #expect(store.person("nobody", in: "design") == nil)
    }
    private func view(kind: ConversationKind, meID: String = "me") -> MessageRowView {
        let view = MessageRowView()
        var message = Message(id: "m", conversationID: "c", sender: Person(id: "a", name: "A"), text: Self.text)
        message.formatting = Self.formatting
        view.configure(TimelineRow.rows([message])[0], own: false, kind: kind, meID: meID,
                       actions: MessageRowActions(message: { _ in }, person: { $0 == "maria" ? Person(id: "maria", name: "Maria Chen", email: "m@x.com") : nil }))
        view.frame = CGRect(x: 0, y: 0, width: 640, height: 200)
        view.layoutSubtreeIfNeeded()
        return view
    }
    private func point(_ view: MessageTextView, at index: Int) -> NSPoint {
        let rect = view.layoutManager!.boundingRect(forGlyphRange: NSRange(location: index, length: 1), in: view.textContainer!)
        return NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)
    }
    @Test func clickingAMentionShowsTheirCard() throws {
        let text = view(kind: .space).textView
        let mention = try #require(text.mention(at: point(text, at: 5)))
        #expect(mention.0 == "maria" && mention.1 == "Maria Chen")
        #expect(text.mention(at: point(text, at: 0)) == nil && text.mention(at: point(text, at: 20)) == nil)
        let menu = try #require(text.mentionMenu?(mention.0, mention.1))
        #expect(menu.items.first?.view != nil && menu.items.last?.title == "Message Maria Chen")
    }
    @Test func noCardInADirectMessageOrForMe() {
        #expect(view(kind: .direct).textView.mentionMenu?("maria", "Maria Chen") == nil)
        #expect(view(kind: .space, meID: "maria").textView.mentionMenu?("maria", "Maria Chen") == nil)
        #expect(view(kind: .space).textView.mentionMenu?("stranger", "Stranger")?.items.last?.title == "Message Stranger")
    }
}
