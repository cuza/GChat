import AppKit
import Testing
@testable import Parley

/// Changes other people make, pushed over the event stream: reactions, conversations, membership.
struct LiveReactionMappingTests {
    private func summary(_ emoji: String, count: Int64, reactors: [String] = [], mine: Bool = false) -> Dynamite_ReactionSummary {
        .with { s in
            s.emoji.unicode = emoji; s.count = count; s.currentUserReacted = mine
            s.reactors = reactors.map { id in .with { $0.id = id } }
        }
    }
    @Test func summariesKeepRealReactorsAndPadToTheCount() {
        let reactions = DynamiteMapper.reactions([
            summary("👍", count: 3, reactors: ["u1", "u2"]),
            summary("❤️", count: 1, mine: true),
            summary("🎉", count: 0, reactors: ["u1"]),   // nobody left: dropped
            summary("", count: 2)                       // custom emoji: not shown
        ], selfID: "me")
        #expect(reactions.map(\.emoji) == ["👍", "❤️"])
        #expect(reactions[0].people.count == 3 && reactions[0].people.isSuperset(of: ["u1", "u2"]) && !reactions[0].people.contains("me"))
        #expect(reactions[1].people == ["me"])
    }
    @Test func listedSelfCountsAsOwnReaction() {
        #expect(DynamiteMapper.reactions([summary("👍", count: 1, reactors: ["me"])], selfID: "me")[0].people == ["me"])
    }
}

extension AuthTests {
    static func reactionsPushed(_ id: (topic: String, message: String), _ summaries: [Dynamite_ReactionSummary], space: String = "x") -> Dynamite_StreamEventsResponse {
        .with {
            $0.event.groupID.spaceID.spaceID = space
            $0.event.bodies = [.with {
                $0.eventType = .batchReactionsUpdated
                $0.batchReactionsUpdated.messageID.parentID.topicID.topicID = id.topic
                $0.batchReactionsUpdated.messageID.messageID = id.message
                $0.batchReactionsUpdated.reactionSummaries = summaries
            }]
        }
    }
    @Test func pushedReactionsReplaceALoadedMessagesReactionsByEmoji() async throws {
        let (backend, _) = try await Self.connected()
        await backend.handle(Self.pushed(.messagePosted, Self.message("h1", topic: "t1", at: 1)))
        await backend.handle(Self.pushed(.messagePosted, Self.message("r1", topic: "t1", at: 2)))
        let thumbs = Dynamite_ReactionSummary.with { s in s.emoji.unicode = "👍"; s.count = 1; s.reactors = [.with { $0.id = "u1" }] }
        await backend.handle(Self.reactionsPushed(("t1", "h1"), [thumbs]))
        await backend.handle(Self.reactionsPushed(("t1", "r1"), [thumbs]))
        await backend.handle(Self.reactionsPushed(("t1", "h1"), [.with { $0.emoji.unicode = "👍"; $0.count = 0 }]))   // everyone took theirs back
        let messages = Self.upserts(await Self.drain(backend)).dropFirst(3)   // h1, r1, and h1's reply count
        #expect(messages.map(\.id) == ["space/x/t1/h1", "space/x/t1/r1", "space/x/t1/h1"])
        #expect(messages.map(\.reactions) == [[Reaction(emoji: "👍", people: ["u1"])], [Reaction(emoji: "👍", people: ["u1"])], []])
        #expect(messages.dropFirst().first?.threadID == "space/x/t1/h1")
        #expect(messages.last?.replyCount == 1)   // the rest of the message is kept
    }
    static func reacted(_ id: (topic: String, message: String), _ emoji: String, by reactor: String, add: Bool) -> Dynamite_StreamEventsResponse {
        .with {
            $0.event.groupID.spaceID.spaceID = "x"
            $0.event.bodies = [.with {
                $0.eventType = .messageReacted
                $0.messageReaction.messageID.parentID.topicID.topicID = id.topic
                $0.messageReaction.messageID.messageID = id.message
                $0.messageReaction.emoji.unicode = emoji
                $0.messageReaction.reactor.id = reactor
                $0.messageReaction.option = add ? .add : .remove
            }]
        }
    }
    /// One person reacting is pushed as its own event: added and removed live, counts known only as a number included.
    @Test func aPushedSingleReactionAddsAndRemovesLive() async throws {
        let (backend, _) = try await Self.connected()
        await backend.handle(Self.pushed(.messagePosted, Self.message("h1", topic: "t1", at: 1)))
        let counted = Dynamite_ReactionSummary.with { s in s.emoji.unicode = "👍"; s.count = 1 }   // someone, not named
        await backend.handle(Self.reactionsPushed(("t1", "h1"), [counted]))
        await backend.handle(Self.reacted(("t1", "h1"), "👍", by: "u2", add: true))
        await backend.handle(Self.reacted(("t1", "h1"), "🎉", by: "u2", add: true))
        await backend.handle(Self.reacted(("t1", "h1"), "👍", by: "u9", add: false))   // the unnamed one takes theirs back
        let last = try #require(Self.upserts(await Self.drain(backend)).last)
        #expect(last.reactions.first { $0.emoji == "👍" }?.people == ["u2"])
        #expect(last.reactions.first { $0.emoji == "🎉" }?.people == ["u2"])
    }
    /// Each live reaction is also announced on its own, for notifications; one replayed by a catch-up is not.
    @Test func aPushedSingleReactionIsAnnouncedOnlyLive() async throws {
        let replayed = Dynamite_CatchUpResponse.with {
            $0.status = .completed
            $0.events = [Self.reacted(("t1", "h1"), "🎉", by: "u3", add: true).event]
        }
        let (backend, _) = try await Self.connected([try Self.proto(replayed)])
        await backend.handle(Self.pushed(.messagePosted, Self.message("h1", topic: "t1", at: 1)))
        await backend.handle(Self.reacted(("t1", "h1"), "👍", by: "u2", add: true))
        await backend.handle(Self.reacted(("t1", "h1"), "👍", by: "u2", add: false))
        await backend.handle(Self.ready)
        await backend.handle(.with { $0.event.userRevision.timestamp = 100 })
        await backend.handle(Self.ready)   // a later ready catches up
        let events = await Self.drain(backend)
        let reacted = events.filter { if case .reacted = $0 { true } else { false } }
        #expect(reacted == [.reacted("space/x/t1/h1", emoji: "👍", by: "u2", added: true),
                            .reacted("space/x/t1/h1", emoji: "👍", by: "u2", added: false)])
        #expect(Self.upserts(events).last?.reactions.contains { $0.emoji == "🎉" } == true)   // the replay still applied
    }
    @Test func pushedReactionsOnAnUnloadedMessageAreIgnored() async throws {
        let (backend, _) = try await Self.connected()
        await backend.handle(Self.reactionsPushed(("t9", "m9"), [.with { $0.emoji.unicode = "👍"; $0.count = 1 }]))
        #expect(Self.upserts(await Self.drain(backend)).isEmpty)
    }
}

extension AuthTests {
    static func membership(_ user: String, _ state: Dynamite_Membership.State, space: String = "x") -> Dynamite_StreamEventsResponse {
        .with {
            $0.event.groupID.spaceID.spaceID = space
            $0.event.bodies = [.with {
                $0.eventType = .membershipChanged
                $0.membershipChanged.newMembership.id.memberID.userID.id = user
                $0.membershipChanged.newMembership.id.groupID.spaceID.spaceID = space
                $0.membershipChanged.newMembership.membershipState = state
            }]
        }
    }
    static func rooms(_ events: [ChatEvent]) -> [Conversation] {
        events.compactMap { if case .conversationUpserted(let room) = $0 { room } else { nil } }
    }
    static func removed(_ events: [ChatEvent]) -> [ConversationID] {
        events.compactMap { if case .conversationRemoved(let id) = $0 { id } else { nil } }
    }
    @Test func leavingOrDeletingAConversationRemovesIt() async throws {
        let (backend, exchange) = try await Self.connected()
        let sent = exchange.requests.count
        await backend.handle(Self.membership("me", .memberNotAMember))
        await backend.handle(.with { $0.event.bodies = [.with { $0.eventType = .groupDeleted; $0.groupDeleted.groupIds = [.with { $0.dmID.dmID = "a" }, .with { $0.dmID.dmID = "b" }] }] })
        await backend.handle(.with {
            $0.event.bodies = [.with { $0.eventType = .groupUpdated; $0.groupUpdated.group.groupID.spaceID.spaceID = "y"; $0.groupUpdated.groupUpdateType = .groupDeleted }]
        })
        #expect(Self.removed(await Self.drain(backend)) == ["space/x", "dm/a", "dm/b", "space/y"])
        #expect(exchange.requests.count == sent)   // nothing to fetch
    }
    @Test func aChangedConversationComesFromTheEventsWorldItem() async throws {
        let (backend, exchange) = try await Self.connected()
        let sent = exchange.requests.count
        await backend.handle(.with {
            $0.event.groupID.spaceID.spaceID = "x"
            $0.event.worldItemLite = .with { $0.groupID.spaceID.spaceID = "x"; $0.roomName = "Launch"; $0.avatarInfo.emoji.unicode = "🚀" }
            $0.event.bodies = [.with { $0.eventType = .groupUpdated; $0.groupUpdated.group.groupID.spaceID.spaceID = "x"; $0.groupUpdated.groupUpdateType = .groupUpdated }]
        })
        let rooms = Self.rooms(await Self.drain(backend))
        #expect(rooms.map(\.id) == ["space/x"] && rooms.first?.name == "Launch" && rooms.first?.emoji == "🚀" && rooms.first?.kind == .space)
        #expect(exchange.requests.count == sent)
    }
    /// Seen live: renaming a group DM pushed an item with the new avatar but no name, and the sidebar kept the old name.
    @Test func aNamelessPushedItemForASpaceIsReadAgain() async throws {
        let world = Dynamite_PaginatedWorldResponse.with {
            $0.worldItems = [.with {
                $0.groupID.spaceID.spaceID = "g"; $0.roomName = "Test Group"; $0.attributes = [.with { $0.type = 6; $0.value = "GROUP_DM" }]
            }]
        }
        let (backend, exchange) = try await Self.connected([try Self.proto(world)])
        await backend.handle(.with {
            $0.event.groupID.spaceID.spaceID = "g"
            $0.event.worldItemLite = .with { $0.groupID.spaceID.spaceID = "g"; $0.avatarURL = "//lh3.example.com/t" }
            $0.event.bodies = [.with { $0.eventType = .groupUpdated; $0.groupUpdated.group.groupID.spaceID.spaceID = "g"; $0.groupUpdated.groupUpdateType = .groupUpdated }]
        })
        let rooms = Self.rooms(await Self.drain(backend))
        #expect(rooms.map(\.name) == ["Test Group"] && rooms.first?.kind == .group)
        #expect(exchange.requests.filter { $0.url?.path == "/api/paginated_world" }.count == 1)
    }
    @Test func otherwiseTheWorldIsReadAgain() async throws {
        let world = Dynamite_PaginatedWorldResponse.with {
            $0.worldItems = [.with { $0.groupID.dmID.dmID = "a"; $0.dmMembers.members = [.with { $0.id = "me" }, .with { $0.id = "u1" }] }]
        }
        let (backend, exchange) = try await Self.connected([try Self.proto(world), try Self.proto(world)])
        await backend.handle(.with {   // a new DM someone started
            $0.event.groupID.dmID.dmID = "a"
            $0.event.bodies = [.with {
                $0.eventType = .membershipChanged
                $0.membershipChanged.newMembership.membershipState = .memberJoined
                $0.membershipChanged.newMembership.id.memberID.userID.id = "me"
            }]
        })
        await backend.handle(Self.membership("u1", .memberJoined, space: "gone"))   // not in the world any more
        let events = await Self.drain(backend)
        let rooms = Self.rooms(events)
        #expect(rooms.map(\.id) == ["dm/a"] && rooms.first?.name == "Maria" && rooms.first?.kind == .direct)
        #expect(Self.removed(events) == ["space/gone"])
        #expect(exchange.requests.filter { $0.url?.path == "/api/paginated_world" }.count == 2)
    }
}

struct SystemMessageTests {
    private let people = ["me": Person(id: "me", name: "Dave"), "u1": Person(id: "u1", name: "Maria"), "u2": Person(id: "u2", name: "Alex")]
    private func event(_ annotations: [Dynamite_Annotation], text: String = "", by user: String = "u1") -> Dynamite_Message {
        .with {
            $0.id.parentID.topicID.topicID = "t1"; $0.id.messageID = "m1"; $0.creator.userID.id = user; $0.createTime = 5_000_000
            $0.textBody = text; $0.annotations = annotations
        }
    }
    private func membership(_ type: Dynamite_MembershipChangedMetadata.TypeEnum, by initiator: String = "", _ affected: [String]) -> Dynamite_Annotation {
        .with { a in
            a.type = .membershipChanged
            a.membershipChanged = .with { m in
                m.type = type; if !initiator.isEmpty { m.initiator.id = initiator }
                m.affectedMembers = affected.map { id in .with { $0.userID.id = id } }
            }
        }
    }
    private func line(_ proto: Dynamite_Message, in conversation: ConversationID = "space/x") -> String? {
        guard let message = DynamiteMapper.message(proto, in: conversation, selfID: "me", people: people) else { return nil }
        #expect(message.isSystem && message.reactions.isEmpty && message.attachments.isEmpty)
        return message.text
    }
    @Test func membershipChangesBecomeServiceLines() {
        #expect(line(event([membership(.added, by: "u1", ["u2"])])) == "Maria added Alex")
        #expect(line(event([membership(.added, ["u2", "me"])])) == "Maria added Alex and you")   // the initiator defaults to the sender
        #expect(line(event([membership(.removed, by: "me", ["u2"])], by: "me")) == "You removed Alex")
        #expect(line(event([membership(.joined, ["u2"])], by: "u2")) == "Alex joined")
        #expect(line(event([membership(.left, [])], by: "me")) == "You left")
        #expect(line(event([membership(.invited, by: "u1", ["me"])])) == "Maria invited you")
    }
    @Test func unknownPeopleUseTheEventsSnapshotName() {
        var added = membership(.added, by: "u1", ["u9"])
        added.membershipChanged.affectedMemberProfiles = [.with { $0.user.userID.id = "u9"; $0.user.name = "Sam" }]
        #expect(line(event([added])) == "Maria added Sam")
        #expect(line(event([membership(.added, by: "u1", ["u8"])])) == "Maria added someone")
    }
    @Test func renamesNameTheSpaceOrConversation() {
        let rename = Dynamite_Annotation.with { a in
            a.type = .roomUpdated
            a.roomUpdated = .with { $0.initiator.userID.id = "u1"; $0.renameMetadata.newName = "Launch"; $0.renameMetadata.prevName = "Old" }
        }
        #expect(line(event([rename], by: "u2")) == "Maria renamed the space to “Launch”")
        #expect(line(event([rename]), in: "dm/a") == "Maria renamed the conversation to “Launch”")
        let details = Dynamite_Annotation.with { $0.roomUpdated.groupDetailsMetadata.newGroupDetails.description_p = "About" }
        #expect(line(event([details])) == "Maria updated the space description to:\nAbout")
        #expect(line(event([membership(.added, ["u2"]), rename])) == "Maria added Alex\nMaria renamed the space to “Launch”")
    }
    @Test func systemEventsWeCannotDescribeAreHidden() {
        // The server's own text on a room update (e.g. "Space Updated") is not shown as a bubble.
        let update = Dynamite_Annotation.with { $0.type = .roomUpdated; $0.roomUpdated.initiator.userID.id = "u1" }
        #expect(DynamiteMapper.message(event([update], text: "Space Updated"), in: "space/x", selfID: "me", people: people) == nil)
        var marked = event([], text: "Something happened")
        marked.messageType = .systemMessage
        #expect(DynamiteMapper.message(marked, in: "space/x", selfID: "me", people: people) == nil)
        #expect(DynamiteMapper.message(event([membership(.roleUpdated, ["u2"])]), in: "space/x", selfID: "me", people: people) == nil)
        marked.messageType = .userMessage   // an ordinary message stays a bubble
        #expect(DynamiteMapper.message(marked, in: "space/x", selfID: "me", people: people)?.isSystem == false)
    }
    @Test func everyoneASystemEventNamesIsLookedUp() {
        let ids = DynamiteMapper.userIDs(event([membership(.added, by: "u3", ["u4", "u5"]),
                                                       .with { $0.roomUpdated.initiator.userID.id = "u6" }]))
        #expect(ids == ["u1", "u3", "u4", "u5", "u6"])
    }
    @Test func cachedMessagesWithoutTheFlagAreNotSystem() throws {
        let old = #"{"id":"m1","conversationID":"c","sender":{"id":"u","name":"U","presence":"offline"},"text":"hi","createdAt":0,"edited":false,"reactions":[],"delivery":"sent","replyCount":0}"#
        #expect(try JSONDecoder().decode(Message.self, from: Data(old.utf8)).isSystem == false)
    }
}

struct ServiceLineLayoutTests {
    static func row(newDay: Bool = false) -> TimelineRow {
        TimelineRow(message: Message(id: "s", conversationID: "c", sender: Person(id: "u", name: "Maria"), text: "Maria added Alex",
                                     createdAt: Date(timeIntervalSince1970: 1_700_000_000), isSystem: true),
                    begins: true, ends: true, newDay: newDay)
    }
    @Test func aServiceLineIsACenteredPillWithoutABubble() throws {
        for own in [false, true] {
            for style in TimelineStyle.allCases {
                let layout = RowLayout.make(Self.row(), width: 700, own: own, kind: .space, style: style)
                let pill = try #require(layout.service)
                #expect(abs(pill.midX - 350) <= 1 && pill.minY > 0 && pill.maxY < layout.height)
                #expect(layout.bubble == .zero && layout.text == nil && layout.name == nil && layout.avatar == nil && layout.retry == nil)
            }
        }
    }
    @Test func aLongServiceLineWrapsInsideTheRow() throws {
        var row = Self.row()
        row = TimelineRow(message: { var m = row.message; m.text = String(repeating: "Maria added someone with a long name. ", count: 12); return m }(),
                          begins: true, ends: true, newDay: false)
        let narrow = try #require(RowLayout.make(row, width: 360, own: false, kind: .space).service)
        let wide = try #require(RowLayout.make(row, width: 1000, own: false, kind: .space).service)
        #expect(narrow.minX >= RowLayout.margin && narrow.maxX <= 360 - RowLayout.margin)
        #expect(narrow.height > wide.height)
    }
    @Test func theDateHeaderStaysAbove() throws {
        let layout = RowLayout.make(Self.row(newDay: true), width: 700, own: false, kind: .space)
        #expect(try #require(layout.dateHeader).maxY < (try #require(layout.service)).minY)
    }
    @MainActor @Test func theRowViewShowsOnlyThePill() throws {
        let view = MessageRowView(frame: NSRect(x: 0, y: 0, width: 700, height: 60))
        view.configure(Self.row(), own: false, kind: .space, meID: "me", actions: MessageRowActions())
        view.layout()
        #expect(!view.serviceLabel.isHidden && view.serviceLabel.text.string == "Maria added Alex")
        #expect(view.bubbleView.isHidden && view.textView.isHidden && view.timeLabel.isHidden && view.avatarView.isHidden)
        #expect(view.menu(for: try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))) == nil)
    }
    @Test func serviceLinesBreakBubbleRuns() {
        let maria = Person(id: "u1", name: "Maria"), at = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = TimelineRow.rows([Message(id: "a", conversationID: "c", sender: maria, text: "one", createdAt: at),
                                     Message(id: "s", conversationID: "c", sender: maria, text: "Maria added Alex", createdAt: at + 1, isSystem: true),
                                     Message(id: "b", conversationID: "c", sender: maria, text: "two", createdAt: at + 2)])
        #expect(rows[0].ends && rows[2].begins)
    }
}

@MainActor
struct LiveConversationStoreTests {
    @Test func serviceLinesNeitherCountAsUnreadNorNotify() async throws {
        let store = ChatStore(backend: FakeBackend()), notifier = RecordingNotifier()
        store.notifier = notifier
        store.notificationSettings = { NotificationSettings() }
        store.isAppActive = { false }
        await store.start()
        let other = try #require(store.conversations.first { $0.id != store.selectedID && !$0.muted })
        store.apply(.messageUpserted(Message(id: "sys", conversationID: other.id, sender: Person(id: "maria", name: "Maria Chen"),
                                             text: "Maria Chen added Alex", isSystem: true)))
        #expect(store.conversations.first { $0.id == other.id }?.unread == other.unread)
        #expect(notifier.posted.isEmpty)
    }
    @Test func upsertedNewConversationsGoFirst() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        store.apply(.conversationUpserted(Conversation(id: "new", name: "New DM", kind: .direct, members: [])))
        #expect(store.conversations.first?.id == "new")
    }
    @Test func removedConversationsLeaveTheSidebarAndTheSelectionMoves() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let selected = try #require(store.selectedID)
        #expect(store.messages.contains { $0.conversationID == selected })
        store.apply(.conversationRemoved(selected))
        #expect(!store.conversations.contains { $0.id == selected })
        #expect(!store.messages.contains { $0.conversationID == selected })
        #expect(store.selectedID != selected && store.selectedID == store.conversations.first?.id)
    }
}

@MainActor
struct LateUpsertTests {
    /// A reaction or edit pushes the whole message again; one the user read long ago is not new unread mail.
    @Test func anOldMessagePushedLateDoesNotCountAsUnread() async throws {
        let store = ChatStore(backend: FakeBackend())
        store.isAppActive = { false }
        await store.start()
        let other = try #require(store.conversations.first { $0.id != store.selectedID && !$0.muted })
        let maria = Person(id: "maria", name: "Maria Chen")
        store.apply(.messageUpserted(Message(id: "old", conversationID: other.id, sender: maria, text: "reacted to", createdAt: .now.addingTimeInterval(-600))))
        #expect(store.conversations.first { $0.id == other.id }?.unread == other.unread)
        store.apply(.messageUpserted(Message(id: "fresh", conversationID: other.id, sender: maria, text: "new", createdAt: .now)))
        #expect(store.conversations.first { $0.id == other.id }?.unread == other.unread + 1)
    }
}

/// Who reacted, for a reaction pill's tooltip.
@MainActor struct ReactorsLineTests {
    @Test func namesOthersFirstThenYouAndCountsTheRest() {
        #expect(ChatStore.reactorsLine(names: [], count: 3) == "3 people")
        #expect(ChatStore.reactorsLine(names: ["You", "Alex"], count: 2) == "Alex and You")
        #expect(ChatStore.reactorsLine(names: ["Alex", "Maria"], count: 3) == ListFormatter.localizedString(byJoining: ["Alex", "Maria", "1 other"]))   // locale's list style
    }
    @Test func reactorsAreFetchedOncePerReactionState() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        store.isAppActive = { false }
        await store.start()
        let sparkles = Reaction(emoji: "✨", people: ["me", "alex"])
        #expect(await store.reactorsLine(sparkles, on: "d2") == "Alex Rivera and You")
        #expect(await store.reactorsLine(sparkles, on: "d2") == "Alex Rivera and You")
        #expect(await fake.reactorRequests == 1)
        await fake.setReaction("✨", custom: nil, on: "d2", present: false)   // the reaction changed: looked up again
        #expect(await store.reactorsLine(Reaction(emoji: "✨", people: ["alex"]), on: "d2") == "Alex Rivera")
        #expect(await fake.reactorRequests == 2)
    }
}

/// My own reactions: shown as soon as the server accepts them, and kept by the summaries it pushes after.
extension AuthTests {
    private static func summary(_ emoji: String, count: Int64, mine: Bool = false) -> Dynamite_ReactionSummary {
        .with { $0.emoji.unicode = emoji; $0.count = count; $0.currentUserReacted = mine }
    }
    /// A pushed summary names only the emoji that changed: a second reaction keeps the first.
    @Test func aSecondReactionKeepsTheFirst() async throws {
        let (backend, _) = try await Self.connected([try Self.proto(Dynamite_UpdateReactionResponse())])
        var head = Self.message("h1", topic: "t1", at: 1)
        head.reactions = [.with { $0.emoji.unicode = "👍"; $0.count = 1; $0.currentUserReacted = true }]
        await backend.handle(Self.pushed(.messagePosted, head))
        try await backend.setReaction("🎉", custom: nil, on: "space/x/t1/h1", present: true)
        await backend.handle(Self.reactionsPushed(("t1", "h1"), [Self.summary("🎉", count: 1, mine: true)]))
        let upserts = Self.upserts(await Self.drain(backend)).filter { $0.id == "space/x/t1/h1" }
        #expect(upserts.dropFirst().map { $0.reactions.map(\.emoji) } == [["👍", "🎉"], ["👍", "🎉"]])
        #expect(upserts.last?.reactions.allSatisfy { $0.people == ["me"] } == true)
    }
    /// A reply in a thread opened from Home, whose conversation was never loaded: my reaction shows, and so do pushed ones.
    @Test func aReactionToAReplyInAThreadLoadedOnItsOwnShows() async throws {
        let replies = Dynamite_ListMessagesResponse.with { $0.messages = [Self.message("r1", topic: "t1", at: 2)]; $0.containsFirstMessage = true }
        let (backend, _) = try await Self.connected([try Self.proto(replies), try Self.proto(Dynamite_UpdateReactionResponse())])
        _ = try await backend.messages(in: "space/x", thread: "space/x/t1/t1", before: nil)
        try await backend.setReaction("👍", custom: nil, on: "space/x/t1/r1", present: true)
        await backend.handle(Self.reactionsPushed(("t1", "r1"), [Self.summary("🎉", count: 1)]))
        let upserts = Self.upserts(await Self.drain(backend)).filter { $0.id == "space/x/t1/r1" }
        #expect(upserts.map { $0.reactions.map(\.emoji) } == [["👍"], ["👍", "🎉"]])
        #expect(upserts.allSatisfy { $0.threadID == "space/x/t1/t1" })
    }
}
