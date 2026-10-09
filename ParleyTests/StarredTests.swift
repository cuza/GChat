import Foundation
import Testing
@testable import Parley

/// Starred messages and the Mentions / Starred shortcuts.
struct StarredMappingTests {
    @Test func aStarLabelMarksTheMessageStarred() throws {
        var proto = AuthTests.message("m1", topic: "t1", at: 1)
        #expect(DynamiteMapper.message(proto, in: "space/x", selfID: "me", people: [:])?.starred == false)
        proto.messageLabels = [.with { $0.type = .pinned }, .with { $0.type = .star }]
        #expect(DynamiteMapper.message(proto, in: "space/x", selfID: "me", people: [:])?.starred == true)
    }
    @Test func launchCachesWithoutTheFlagStillDecode() throws {
        let json = #"{"id":"a","conversationID":"c","sender":{"id":"p","name":"P","presence":"offline"},"text":"t","createdAt":0,"edited":false,"reactions":[],"delivery":"sent","replyCount":0}"#
        let message = try JSONDecoder().decode(Message.self, from: Data(json.utf8))
        #expect(message.starred == false)
        var starred = message; starred.starred = true
        #expect(try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(starred)).starred)
    }
    @Test func shortcutsComeFirstInWebOrder() {
        let gemini = Conversation(id: "g", name: "Ask Gemini", kind: .direct, members: [], app: .gemini)
        let sections = Conversation.sidebarSections([gemini])
        #expect(sections.first?.title == "Shortcuts" && sections.first?.rooms == [gemini])
        #expect(Shortcut.allCases == [.home, .mentions, .starred, .drafts] && Shortcut.allCases.map(\.title) == ["Home", "Mentions", "Starred", "Drafts"])
    }
}

extension AuthTests {
    @Test func starringAppliesAndUnstarringRemovesTheStarLabel() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_ApplyMessageLabelResponse()), try Self.proto(Dynamite_RemoveMessageLabelResponse())])
        await backend.handle(Self.pushed(.messagePosted, Self.message("h1", topic: "t1", at: 1)))
        try await backend.setStarred(true, on: "space/x/t1/h1")
        try await backend.setStarred(false, on: "space/x/t1/h1")
        let paths = exchange.requests.map { $0.url?.path }
        #expect(paths.suffix(2) == ["/api/apply_message_label", "/api/remove_message_label"])
        for request in exchange.requests.suffix(2) {
            let sent = try Dynamite_MessageLabelRequest(serializedBytes: Self.body(request))
            #expect(sent.messageID.messageID == "h1" && sent.messageID.parentID.topicID.topicID == "t1"
                    && sent.messageID.parentID.topicID.groupID.spaceID.spaceID == "x")
            #expect(sent.label.type == .star && sent.hasRequestHeader)
        }
        #expect(Self.upserts(await Self.drain(backend)).map(\.starred) == [false, true, false])
    }
    /// A copy in a shortcut's hidden space, naming `original` as Google Chat sends it (field 42).
    static func copy(of original: Dynamite_Message, as copyID: String) -> Dynamite_Message {
        var copy = original
        copy.id.parentID.topicID.topicID = copyID; copy.id.messageID = copyID
        copy.id.parentID.topicID.groupID = .with { $0.spaceID.spaceID = "shortcut" }
        copy.shortcutSource.ref.messageID = original.id
        return copy
    }
    /// The copy's field 42 as Google Chat sends it: {1: {1: original MessageId, 2: 1}}.
    @Test func aCopyNamesItsOriginalTwoLevelsDown() throws {
        let original: [UInt8] = try Dynamite_MessageId.with {
            $0.parentID.topicID.topicID = "t1"; $0.parentID.topicID.groupID.dmID.dmID = "d"; $0.messageID = "m1"
        }.serializedBytes()
        let ref: [UInt8] = [0x0A, UInt8(original.count)] + original + [0x10, 0x01]
        let source: [UInt8] = [0x0A, UInt8(ref.count)] + ref
        let message = try Dynamite_Message(serializedBytes: [0xD2, 0x02, UInt8(source.count)] + source)   // field 42, length-delimited
        #expect(message.shortcutSource.ref.messageID.messageID == "m1")
        #expect(message.shortcutSource.ref.messageID.parentID.topicID.groupID.dmID.dmID == "d")
    }
    static let shortcutWorld = Dynamite_PaginatedWorldResponse.with { $0.worldItems = [.with { $0.groupID.spaceID.spaceID = "shortcut" }] }
    @Test func starredListsTheHiddenShortcutSpaceAndPages() async throws {
        var starred = Self.message("m1", topic: "t1", at: 5)
        starred.id.parentID.topicID.groupID.spaceID.spaceID = "x"
        var older = Self.message("m2", topic: "m2", at: 3)
        older.id.parentID.topicID.groupID.dmID.dmID = "d"
        let first = Dynamite_ListTopicsResponse.with { r in
            r.topics = [.with { $0.sortTime = 50; $0.replies = [Self.copy(of: starred, as: "c1")] },
                        .with { $0.sortTime = 30; $0.replies = [Self.copy(of: older, as: "c2")] }]
        }
        let last = Dynamite_ListTopicsResponse.with { $0.containsFirstTopic = true }
        let (backend, exchange) = try await Self.connected([try Self.proto(Self.shortcutWorld), try Self.proto(first), try Self.proto(last)])
        let page = try await backend.shortcut(.starred, cursor: nil)
        #expect(page.messages.map(\.id) == ["space/x/t1/m1", "dm/d/m2/m2"] && page.messages.allSatisfy(\.starred))
        #expect(page.messages[0].threadID == "space/x/t1/t1")   // a reply: it opens in its thread
        #expect(page.cursor == "30")
        let next = try await backend.shortcut(.starred, cursor: page.cursor)
        #expect(next.messages.isEmpty && next.cursor == nil)
        let worlds = try exchange.requests.filter { $0.url?.path == "/api/paginated_world" }.map { try Dynamite_PaginatedWorldRequest(serializedBytes: Self.body($0)) }
        #expect(worlds.count == 1)   // the space is asked for once
        let section = try #require(worlds.first?.worldSectionRequests.first)
        #expect(section.worldFilter.shortcutTypes == [.starred] && section.worldFilter.groupType == .room && section.pageSize == 30)
        let topics = try exchange.requests.filter { $0.url?.path == "/api/list_topics" }.map { try Dynamite_ListTopicsRequest(serializedBytes: Self.body($0)) }
        #expect(topics.map(\.groupID.spaceID.spaceID) == ["shortcut", "shortcut"])
        #expect(!topics[0].hasFilter && topics[1].filter.olderThan == 30)
    }
    /// Personal (non-Workspace) accounts have no shortcut spaces: Google Chat shows these lists empty.
    @Test func withoutShortcutSpacesTheListsAreEmpty() async throws {
        let refused = StubExchange.Reply(status: 403)
        let (backend, _) = try await Self.connected([refused, Self.xsrfReply, refused, Self.xsrfReply, try Self.proto(Dynamite_PaginatedWorldResponse())])
        let mentions = try await backend.shortcut(.mentions, cursor: nil)
        #expect(mentions.messages.isEmpty && mentions.cursor == nil)
        let starred = try await backend.shortcut(.starred, cursor: nil)
        #expect(starred.messages.isEmpty && starred.cursor == nil)
    }
    @Test func mentionsListTheOriginalsOfTheHiddenSpacesCopies() async throws {
        var mention = Self.message("t1", topic: "t1", at: 2)
        mention.id.parentID.topicID.groupID.dmID.dmID = "drive"
        mention.textBody = "@Dave look"
        let stray = Self.message("t9", topic: "t9", at: 4)   // no original named: not listed
        let topics = Dynamite_ListTopicsResponse.with { r in
            r.topics = [.with { $0.replies = [Self.copy(of: mention, as: "c1")] }, .with { $0.replies = [stray] }]
            r.containsFirstTopic = true
        }
        let (backend, exchange) = try await Self.connected([try Self.proto(Self.shortcutWorld), try Self.proto(topics)])
        let page = try await backend.shortcut(.mentions, cursor: nil)
        #expect(page.messages.map(\.id) == ["dm/drive/t1/t1"] && page.cursor == nil)
        #expect(page.messages.first?.starred == false)
        let sent = try Dynamite_PaginatedWorldRequest(serializedBytes: Self.body(try #require(exchange.requests.first { $0.url?.path == "/api/paginated_world" })))
        #expect(sent.worldSectionRequests.first?.worldFilter.shortcutTypes == [.mentions])
    }
}

@MainActor
struct StarredStoreTests {
    private func started(latency: Duration = .zero) async -> (ChatStore, FakeBackend) {
        let fake = FakeBackend(latency: latency)
        let store = ChatStore(backend: fake)
        await store.start()
        return (store, fake)
    }
    @Test func starShowsAtOnceAndReachesTheServer() async throws {
        let (store, fake) = await started(latency: .milliseconds(300))
        let message = try #require(store.messages.first { $0.id == "d1" })
        let pending = Task { await store.setStarred(true, message) }
        try await Task.sleep(for: .milliseconds(80))
        #expect(store.messages.first { $0.id == "d1" }?.starred == true)
        await pending.value
        #expect(await fake.changes == ["star d1"])
        await store.openShortcut(.starred)
        #expect(store.shortcutMessages(.starred).map(\.id).contains("d1"))
    }
    @Test func aRefusedStarIsPutBack() async throws {
        let (store, fake) = await started()
        await fake.simulateChangeFailure()
        let message = try #require(store.messages.first { $0.id == "d1" })
        await store.setStarred(true, message)
        #expect(store.messages.first { $0.id == "d1" }?.starred == false && store.error != nil)
    }
    @Test func unstarringFromTheStarredListTakesItOff() async throws {
        let (store, _) = await started()
        await store.openShortcut(.starred)
        let starred = try #require(store.shortcutMessages(.starred).first)
        await store.setStarred(false, starred)
        #expect(!store.shortcutMessages(.starred).contains { $0.id == starred.id })
    }
    @Test func shortcutsListMessagesAndChoosingOneOpensIt() async throws {
        let (store, _) = await started()
        await store.openShortcut(.mentions)
        #expect(store.shortcut == .mentions)
        let mention = try #require(store.shortcutMessages(.mentions).first)
        await store.showInChat(mention)
        #expect(store.shortcut == nil && store.selectedID == mention.conversationID && store.highlightedID == mention.id)
    }
    @Test func selectingAConversationLeavesTheShortcut() async throws {
        let (store, _) = await started()
        await store.openShortcut(.starred)
        await store.select("alex")
        #expect(store.shortcut == nil)
    }
}

@MainActor struct StarMenuTests {
    @Test func theMenuOffersStarOrUnstarAndTheTimeShowsTheStar() throws {
        var calls: [Bool] = []
        var message = Message(id: "m", conversationID: "c", sender: Person(id: "a", name: "X"), text: "hi")
        let view = MessageRowView()
        let actions = MessageRowActions(star: { starred, _ in calls.append(starred) })
        view.configure(TimelineRow.rows([message])[0], own: false, kind: .space, meID: "me", actions: actions)
        let item = try #require(view.contextMenu().items.first { $0.title == "Star" })
        item.target.map { _ = ($0 as AnyObject).perform(item.action, with: item) }
        #expect(calls == [true] && !RowLayout.timeText(message).string.contains("★"))
        message.starred = true
        view.configure(TimelineRow.rows([message])[0], own: false, kind: .space, meID: "me", actions: actions)
        #expect(view.contextMenu().items.contains { $0.title == "Unstar" })
        #expect(RowLayout.timeText(message).string.hasPrefix("★"))
    }
}
