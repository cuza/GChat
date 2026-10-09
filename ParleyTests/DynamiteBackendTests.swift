import Foundation
import SwiftProtobuf
import Testing
@testable import Parley

/// Network-stubbed tests share AuthStubProtocol's global registry, so they join the serialized AuthTests suite.
extension AuthTests {
    static let xsrfReply = StubExchange.Reply(data: Data(#"{"SMqcke":"test-xsrf"}"#.utf8))
    static func proto(_ message: some SwiftProtobuf.Message) throws -> StubExchange.Reply {
        .init(headers: ["Content-Type": "application/x-protobuf"], data: try message.serializedBytes())
    }
    static func signedIn(_ replies: [StubExchange.Reply]) throws -> (WebSessionAuthorizer, StubExchange) {
        let vault = MemoryVault()
        let cookie = SessionCookie(name: "SID", value: "test-session", domain: ".google.com", path: "/", secure: true, expires: -1)
        vault.write(try JSONEncoder().encode(WebCredentials(cookies: [cookie], userAgent: "TestAgent/1")))
        let exchange = StubExchange([xsrfReply] + replies)
        return (WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange)), exchange)
    }

    @Test func clientPostsBinaryProtoWithRtB() async throws {
        let response = Dynamite_GetSelfUserStatusResponse.with { $0.userStatus.userID.id = "me-id" }
        let (auth, exchange) = try Self.signedIn([try Self.proto(response)])
        let client = DynamiteClient(authorizer: auth)
        let decoded: Dynamite_GetSelfUserStatusResponse = try await client.call(
            "get_self_user_status", Dynamite_GetSelfUserStatusRequest.with { $0.requestHeader = DynamiteClient.header })
        #expect(decoded.userStatus.userID.id == "me-id")
        let rpc = try #require(exchange.requests.last)
        #expect(rpc.url?.absoluteString == "https://chat.google.com/api/get_self_user_status?rt=b")
        #expect(rpc.httpMethod == "POST")
        #expect(rpc.value(forHTTPHeaderField: "Content-Type") == "application/x-protobuf")
    }
    /// URLSession can hand a request to a keep-alive connection the server already closed: one retry, as on a fresh one.
    @Test func clientRetriesOnceWhenTheConnectionWasLost() async throws {
        let response = Dynamite_GetSelfUserStatusResponse.with { $0.userStatus.userID.id = "me-id" }
        let (auth, exchange) = try Self.signedIn([.init(failure: .networkConnectionLost), try Self.proto(response)])
        let decoded: Dynamite_GetSelfUserStatusResponse = try await DynamiteClient(authorizer: auth).call(
            "get_self_user_status", Dynamite_GetSelfUserStatusRequest())
        #expect(decoded.userStatus.userID.id == "me-id")
        #expect(exchange.requests.filter { $0.url?.path == "/api/get_self_user_status" }.count == 2)
        let (twice, _) = try Self.signedIn([.init(failure: .networkConnectionLost), .init(failure: .networkConnectionLost)])
        await #expect(throws: URLError.self) {
            let _: Dynamite_GetSelfUserStatusResponse = try await DynamiteClient(authorizer: twice).call(
                "get_self_user_status", Dynamite_GetSelfUserStatusRequest())
        }
    }
    @Test func clientMapsUndecodableBodyToMalformedProto() async throws {
        let garbage = StubExchange.Reply(headers: ["Content-Type": "application/x-protobuf"], data: Data([0xFF, 0xFF, 0xFF]))
        let (auth, _) = try Self.signedIn([garbage])
        await #expect(throws: AuthFailure.malformedProto) {
            let _: Dynamite_GetSelfUserStatusResponse = try await DynamiteClient(authorizer: auth).call(
                "get_self_user_status", Dynamite_GetSelfUserStatusRequest())
        }
    }
}

extension AuthTests {
    private static func selfReply(_ id: String = "me") throws -> StubExchange.Reply {
        try proto(Dynamite_GetSelfUserStatusResponse.with { $0.userStatus.userID.id = id })
    }
    private static func members(_ pairs: [(String, String)]) throws -> StubExchange.Reply {
        try proto(Dynamite_GetMembersResponse.with { $0.memberProfiles = pairs.map { id, name in .with { $0.member.user.userID.id = id; $0.member.user.name = name } } })
    }
    private static func item(dm id: String, members: [String], sort: Int64, unread: Int64 = 0) -> Dynamite_WorldItemLite {
        .with {
            $0.groupID.dmID.dmID = id; $0.sortTimestamp = sort; $0.readState.unreadMessageCount = unread
            $0.dmMembers.members = members.map { m in .with { $0.id = m } }
        }
    }
    static func message(_ id: String, topic: String, at: Int64, by user: String = "u1") -> Dynamite_Message {
        .with { $0.id.parentID.topicID.topicID = topic; $0.id.messageID = id; $0.createTime = at; $0.creator.userID.id = user; $0.textBody = id }
    }

    @Test func connectReturnsSignedInPerson() async throws {
        let (auth, _) = try Self.signedIn([try Self.selfReply(), try Self.members([("me", "Dave")])])
        let me = try await DynamiteBackend(authorizer: auth, realtime: false).connect()
        #expect(me == Person(id: "me", name: "Dave"))
    }
    /// Raw bytes pin the wire layout: request `membership_ids = 2`
    /// {member_id(1){user_id(1)}}, response `member_profiles = 2` {member(2){user(1)}}; field 1 is absent in this build.
    @Test func getMembersUsesFieldTwo() async throws {
        let user: [UInt8] = [0x0A, 0x04, 0x0A, 0x02, 0x6D, 0x65, 0x12, 0x04, 0x44, 0x61, 0x76, 0x65]   // User{user_id{"me"}, name "Dave"}
        let response = Data([0x12, 0x10, 0x12, 0x0E, 0x0A, 0x0C] + user)
        let (auth, exchange) = try Self.signedIn([try Self.selfReply(), .init(headers: ["Content-Type": "application/x-protobuf"], data: response)])
        let me = try await DynamiteBackend(authorizer: auth, realtime: false).connect()
        #expect(me == Person(id: "me", name: "Dave"))
        let request = try #require(exchange.requests.last)
        #expect(Self.body(request).prefix(10) == Data([0x12, 0x08, 0x0A, 0x06, 0x0A, 0x04, 0x0A, 0x02, 0x6D, 0x65]))
    }
    @Test func connectReportsSignedOutWhenNoSession() async throws {
        let auth = WebSessionAuthorizer(vault: MemoryVault(), session: AuthStubProtocol.session(StubExchange([])))
        await #expect(throws: AuthFailure.signInRequired) { _ = try await DynamiteBackend(authorizer: auth, realtime: false).connect() }
    }
    @Test func conversationsPaginateDedupeSortAndName() async throws {
        let first = Dynamite_PaginatedWorldResponse.with {
            $0.worldSectionResponses = [.with {
                $0.worldItems = [Self.item(dm: "a", members: ["me", "u1"], sort: 1, unread: 2)]
                $0.moreItems = true; $0.paginationToken = "next"
            }]
        }
        let second = Dynamite_PaginatedWorldResponse.with {
            $0.worldItems = [Self.item(dm: "b", members: ["me", "u2"], sort: 9), Self.item(dm: "a", members: ["me", "u1"], sort: 1)]
        }
        let (auth, exchange) = try Self.signedIn([
            try Self.selfReply(), try Self.members([("me", "Dave")]),
            try Self.proto(first), try Self.proto(second),
            try Self.members([("u1", "Maria"), ("u2", "Alex")])
        ])
        let backend = DynamiteBackend(authorizer: auth, realtime: false)
        _ = try await backend.connect()
        let rooms = try await backend.conversations()
        #expect(rooms.map(\.id) == ["dm/b", "dm/a"])        // newest first, deduplicated
        #expect(rooms.map(\.name) == ["Alex", "Maria"])
        #expect(rooms[1].unread == 2)
        #expect(exchange.requests.map { $0.url!.path } == ["/mole/world", "/api/get_self_user_status", "/api/get_members", "/api/paginated_world", "/api/paginated_world", "/api/get_members"])
        // Checked live: only as the web client does Google include a group DM's name and GROUP_DM attribute.
        let worlds = try exchange.requests.filter { $0.url?.path == "/api/paginated_world" }
            .map { try Dynamite_PaginatedWorldRequest(serializedBytes: Self.body($0)) }
        #expect(!worlds.isEmpty && worlds.allSatisfy { $0.requestHeader.clientType == .web })
    }
    @Test func memberLookupFailureStillListsConversations() async throws {
        let world = Dynamite_PaginatedWorldResponse.with { $0.worldItems = [Self.item(dm: "a", members: ["me", "u1"], sort: 1)] }
        let (auth, _) = try Self.signedIn([
            try Self.selfReply(), try Self.members([("me", "Dave")]),
            try Self.proto(world), .init(status: 500)
        ])
        let backend = DynamiteBackend(authorizer: auth, realtime: false)
        _ = try await backend.connect()
        #expect(try await backend.conversations().map(\.name) == ["Unknown"])
    }
    @Test func repeatedWorldCursorFails() async throws {
        let looping = Dynamite_PaginatedWorldResponse.with { $0.worldSectionResponses = [.with { $0.moreItems = true; $0.paginationToken = "same" }] }
        let (auth, _) = try Self.signedIn([try Self.selfReply(), try Self.members([("me", "Dave")]), try Self.proto(looping), try Self.proto(looping)])
        let backend = DynamiteBackend(authorizer: auth, realtime: false)
        _ = try await backend.connect()
        await #expect(throws: AuthFailure.malformedProto) { _ = try await backend.conversations() }
    }
    @Test func historyReturnsHeadsAndThreadsServeReplies() async throws {
        let topics = Dynamite_ListTopicsResponse.with {
            $0.topics = [
                .with { $0.replies = [Self.message("h1", topic: "t1", at: 1), Self.message("r1", topic: "t1", at: 2)] },
                .with { $0.replies = [Self.message("h2", topic: "t2", at: 3)] }
            ]
        }
        let (auth, _) = try Self.signedIn([try Self.selfReply(), try Self.members([("me", "Dave")]), try Self.proto(topics), try Self.members([("u1", "Maria")]),
            try Self.proto(Dynamite_ListMessagesResponse.with { $0.messages = [Self.message("h1", topic: "t1", at: 1), Self.message("r1", topic: "t1", at: 2)]; $0.containsFirstMessage = true })])
        let backend = DynamiteBackend(authorizer: auth, realtime: false)
        _ = try await backend.connect()
        let page = try await backend.messages(in: "space/x", thread: nil, before: nil)
        #expect(page.messages.map(\.id) == ["space/x/t1/h1", "space/x/t2/h2"])
        #expect(page.messages[0].replyCount == 1 && page.hasMore)   // fixture has no contains_first_topic
        let thread = try await backend.messages(in: "space/x", thread: "space/x/t1/h1", before: nil)
        #expect(thread.messages.map(\.id) == ["space/x/t1/r1"])
        #expect(try await backend.messages(in: "space/x", thread: nil, before: .now).messages.isEmpty)
    }
    @Test func sendNewTopicReturnsServerMessage() async throws {
        let created = Dynamite_CreateTopicResponse.with { $0.topic.replies = [Self.message("m9", topic: "t9", at: 5, by: "me")] }
        let (auth, exchange) = try Self.signedIn([try Self.selfReply(), try Self.members([("me", "Dave")]), try Self.proto(created)])
        let backend = DynamiteBackend(authorizer: auth, realtime: false)
        _ = try await backend.connect()
        let sent = try await backend.send(MessageDraft(text: "m9", localID: "local-1"), to: "dm/a", thread: nil)
        #expect(sent.id == "dm/a/t9/m9" && sent.sender.name == "Dave" && sent.threadID == nil)
        #expect(exchange.requests.last?.url?.path == "/api/create_topic")
    }
    @Test func replyGoesToCreateMessageInThread() async throws {
        let created = Dynamite_CreateMessageResponse.with { $0.message = Self.message("r5", topic: "t1", at: 6, by: "me") }
        let (auth, exchange) = try Self.signedIn([try Self.selfReply(), try Self.members([("me", "Dave")]), try Self.proto(created)])
        let backend = DynamiteBackend(authorizer: auth, realtime: false)
        _ = try await backend.connect()
        let sent = try await backend.send(MessageDraft(text: "r5", localID: "local-2"), to: "space/x", thread: "space/x/t1/h1")
        #expect(sent.threadID == "space/x/t1/h1")
        #expect(exchange.requests.last?.url?.path == "/api/create_message")
    }
}

extension AuthTests {
    @Test func sessionExpiringMidUseReportsSignedOut() async throws {
        let me = try Self.proto(Dynamite_GetSelfUserStatusResponse.with { $0.userStatus.userID.id = "me" })
        let (auth, _) = try Self.signedIn([me, .init(status: 500), .init(status: 401), Self.xsrfReply, Self.signInPage])
        let backend = DynamiteBackend(authorizer: auth, realtime: false)
        _ = try await backend.connect()
        await #expect(throws: AuthFailure.signInRequired) { try await backend.markRead("dm/a") }
        await backend.disconnect()   // .offline marks the end of what to read
        var states: [ConnectionState] = []
        for await event in backend.events {
            guard case .connectionChanged(let state) = event else { continue }
            states.append(state)
            if state == .offline { break }
        }
        #expect(states == [.connecting, .signedOut, .offline])
    }
}

extension AuthTests {
    static func connected(_ extra: [StubExchange.Reply] = []) async throws -> (DynamiteBackend, StubExchange) {
        let me = try proto(Dynamite_GetSelfUserStatusResponse.with { $0.userStatus.userID.id = "me" })
        let people = try proto(Dynamite_GetMembersResponse.with {
            $0.memberProfiles = [("me", "Dave"), ("u1", "Maria")].map { id, name in .with { $0.member.user.userID.id = id; $0.member.user.name = name } }
        })
        let (auth, exchange) = try signedIn([me, people] + extra)
        let backend = DynamiteBackend(authorizer: auth, realtime: false)
        _ = try await backend.connect()
        return (backend, exchange)
    }
    /// Everything the backend emitted so far; disconnect's `.offline` marks the end.
    static func drain(_ backend: DynamiteBackend) async -> [ChatEvent] {
        await backend.disconnect()
        var events: [ChatEvent] = []
        for await event in backend.events {
            if event == .connectionChanged(.offline) { break }
            events.append(event)
        }
        return events
    }
    static func pushed(_ type: Dynamite_EventBody.EventType, _ message: Dynamite_Message, space: String = "x") -> Dynamite_StreamEventsResponse {
        .with { $0.event.groupID.spaceID.spaceID = space; $0.event.bodies = [.with { $0.eventType = type; $0.messagePosted.message = message }] }
    }
    static func upserts(_ events: [ChatEvent]) -> [Parley.Message] {
        events.compactMap { if case .messageUpserted(let message) = $0 { message } else { nil } }
    }
    static let ready = Dynamite_StreamEventsResponse.with { $0.event.bodies = [.with { $0.eventType = .sessionReady }] }

    @Test func pushedMessagesBecomeHeadsAndReplies() async throws {
        let (backend, _) = try await Self.connected()
        await backend.handle(Self.pushed(.messagePosted, Self.message("h1", topic: "t1", at: 1)))
        await backend.handle(Self.pushed(.messagePosted, Self.message("r1", topic: "t1", at: 2)))
        await backend.handle(Self.pushed(.messageUpdated, Self.message("r1", topic: "t1", at: 2)))   // edit: no second bump
        let messages = Self.upserts(await Self.drain(backend))
        #expect(messages.map(\.id) == ["space/x/t1/h1", "space/x/t1/r1", "space/x/t1/h1", "space/x/t1/r1"])
        #expect(messages[0].sender.name == "Maria" && messages[0].threadID == nil)
        #expect(messages[1].threadID == "space/x/t1/h1")
        #expect(messages[2].replyCount == 1)
    }
    @Test func pushedDeletesAndTombstonesRemoveMessages() async throws {
        let (backend, _) = try await Self.connected()
        await backend.handle(.with {
            $0.event.groupID.dmID.dmID = "a"
            $0.event.bodies = [.with { $0.eventType = .messageDeleted; $0.messageDeleted.messageID.parentID.topicID.topicID = "t1"; $0.messageDeleted.messageID.messageID = "m1" }]
        })
        var tombstone = Self.message("m2", topic: "t2", at: 1); tombstone.deleteTime = 5
        await backend.handle(Self.pushed(.messageUpdated, tombstone))
        let deleted = await Self.drain(backend).compactMap { if case .messageDeleted(let id) = $0 { id } else { nil } }
        #expect(deleted == ["dm/a/t1/m1", "space/x/t2/m2"])
    }
    @Test func sessionReadyConnectsAndLaterReadyCatchesUp() async throws {
        let caughtUp = Dynamite_CatchUpResponse.with {
            $0.status = .completed
            $0.events = [.with { $0.groupID.dmID.dmID = "a"; $0.bodies = [.with { $0.eventType = .messagePosted; $0.messagePosted.message = Self.message("m7", topic: "t7", at: 9) }] }]
        }
        let (backend, exchange) = try await Self.connected([try Self.proto(caughtUp)])
        await backend.handle(Self.ready)
        await backend.handle(.with { $0.event.userRevision.timestamp = 100 })
        await backend.handle(Self.ready)
        let events = await Self.drain(backend)
        #expect(events.filter { $0 == .connectionChanged(.connected) }.count == 2)
        #expect(Self.upserts(events).map(\.id) == ["dm/a/t7/m7"])
        #expect(exchange.requests.last?.url?.path == "/api/catch_up_user")
        #expect(!events.contains(.resync))
    }
    /// While the realtime channel is down, polling catch_up_user brings the events in as if pushed, from the
    /// revision already seen; one at that revision (a replay) is skipped so a reaction toggle never applies twice.
    @Test func pollingBringsNewEventsInOnce() async throws {
        func posted(_ id: String, at revision: Int64) -> Dynamite_Event {
            .with { $0.userRevision.timestamp = revision; $0.groupID.dmID.dmID = "a"
                $0.bodies = [.with { $0.eventType = .messagePosted; $0.messagePosted.message = Self.message(id, topic: id, at: 9) }] }
        }
        let polled = Dynamite_CatchUpResponse.with { $0.status = .completed; $0.events = [posted("m1", at: 100), posted("m2", at: 200)] }
        let (backend, exchange) = try await Self.connected([try Self.proto(polled), try Self.members([("u1", "Maria")]), .init(status: 500)])
        await backend.handle(.with { $0.event.userRevision.timestamp = 100 })
        #expect(await backend.poll())
        let events = await Self.drain(backend)
        #expect(Self.upserts(events).map(\.id) == ["dm/a/m2/m2"])
        #expect(events.contains(.connectionChanged(.connected)) && !events.contains(.resync))
        let sent = try Dynamite_CatchUpUserRequest(serializedBytes: Self.body(try #require(exchange.requests.last { $0.url?.path == "/api/catch_up_user" })))
        #expect(sent.range.fromRevisionTimestamp == 100)
        #expect(!(await backend.poll()))   // a failed round changes nothing and asks for no resync
    }
    @Test func failedCatchUpAsksForResync() async throws {
        let (backend, _) = try await Self.connected([try Self.proto(Dynamite_CatchUpResponse.with { $0.status = .abortedFromRevisionTooOld })])
        await backend.handle(Self.ready)
        await backend.handle(.with { $0.event.userRevision.timestamp = 100 })
        await backend.handle(Self.ready)
        #expect(await Self.drain(backend).contains(.resync))
    }
    @Test func readyWithoutAnyRevisionResyncsWithoutCatchUp() async throws {
        let (backend, exchange) = try await Self.connected()
        await backend.handle(Self.ready)
        await backend.handle(Self.ready)
        #expect(await Self.drain(backend).contains(.resync))
        #expect(!exchange.requests.contains { $0.url?.path == "/api/catch_up_user" })
    }
}

extension AuthTests {
    @Test func groupRevisionAlsoDrivesCatchUp() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_CatchUpResponse.with { $0.status = .completed })])
        await backend.handle(Self.ready)
        await backend.handle(.with { $0.event.groupRevision.timestamp = 100 })
        await backend.handle(Self.ready)
        #expect(!(await Self.drain(backend)).contains(.resync))
        #expect(exchange.requests.last?.url?.path == "/api/catch_up_user")
    }
}

extension AuthTests {
    @Test func reconnectAfterSignInDoesNotCatchUp() async throws {
        let again = try Self.proto(Dynamite_GetSelfUserStatusResponse.with { $0.userStatus.userID.id = "me" })
        let (backend, _) = try await Self.connected([again])
        await backend.handle(Self.ready)
        _ = try await backend.connect()   // signed in again: a fresh load follows
        await backend.handle(Self.ready)
        #expect(!(await Self.drain(backend)).contains(.resync))
    }
    @Test func deletingAReplyLowersTheHeadCount() async throws {
        let (backend, _) = try await Self.connected()
        func push(_ type: Dynamite_EventBody.EventType, _ id: String) -> Dynamite_StreamEventsResponse {
            .with {
                $0.event.groupID.spaceID.spaceID = "x"
                $0.event.bodies = [.with {
                    $0.eventType = type
                    if type == .messageDeleted { $0.messageDeleted.messageID.parentID.topicID.topicID = "t1"; $0.messageDeleted.messageID.messageID = id }
                    else { $0.messagePosted.message = Self.message(id, topic: "t1", at: id == "h1" ? 1 : 2) }
                }]
            }
        }
        await backend.handle(push(.messagePosted, "h1"))
        await backend.handle(push(.messagePosted, "r1"))
        await backend.handle(push(.messageDeleted, "r1"))
        let heads = await Self.drain(backend).compactMap { if case .messageUpserted(let m) = $0, m.id == "space/x/t1/h1" { m.replyCount } else { nil } }
        #expect(heads == [0, 1, 0])
    }
}

extension AuthTests {
    private static func topic(_ id: String, sort: Int64) -> Dynamite_Topic {
        .with { $0.sortTime = sort; $0.replies = [message(id, topic: id, at: sort)] }
    }
    @Test func olderHistoryAnchorsOnOldestSortTime() async throws {
        let recent = Dynamite_ListTopicsResponse.with { $0.topics = [Self.topic("t3", sort: 300), Self.topic("t2", sort: 200)] }
        let older = Dynamite_ListTopicsResponse.with { $0.topics = [Self.topic("t2", sort: 200), Self.topic("t1", sort: 100)]; $0.containsFirstTopic = true }
        let (backend, exchange) = try await Self.connected([try Self.proto(recent), try Self.proto(older)])
        let first = try await backend.messages(in: "dm/a", thread: nil, before: nil)
        #expect(first.hasMore)
        let page = try await backend.messages(in: "dm/a", thread: nil, before: .now)
        #expect(page.messages.map(\.id) == ["dm/a/t2/t2", "dm/a/t1/t1"] && !page.hasMore)
        #expect(exchange.requests.filter { $0.url?.path == "/api/list_topics" }.count == 2)
        let last = try await backend.messages(in: "dm/a", thread: nil, before: .now)   // nothing older: no request
        #expect(last.messages.isEmpty && !last.hasMore)
        #expect(exchange.requests.filter { $0.url?.path == "/api/list_topics" }.count == 2)
    }
    @Test func sendsCarryClientGeneratedMessageIDs() async throws {
        let topic = try Self.proto(Dynamite_CreateTopicResponse.with { $0.topic.replies = [Self.message("m9", topic: "m9", at: 5, by: "me")] })
        let reply = try Self.proto(Dynamite_CreateMessageResponse.with { $0.message = Self.message("r9", topic: "m9", at: 6, by: "me") })
        let (backend, _) = try await Self.connected([topic, reply])
        let sent = try await backend.send(MessageDraft(text: "hi", localID: "local-1"), to: "dm/a", thread: nil)
        #expect(sent.id == "dm/a/m9/m9")
        let replied = try await backend.send(MessageDraft(text: "re", localID: "local-2"), to: "dm/a", thread: sent.id)
        #expect(replied.threadID == sent.id)
    }
    @Test func resendingADraftReusesItsClientMessageID() async throws {
        let topic = try Self.proto(Dynamite_CreateTopicResponse.with { $0.topic.replies = [Self.message("m9", topic: "m9", at: 5, by: "me")] })
        let reply = try Self.proto(Dynamite_CreateMessageResponse.with { $0.message = Self.message("r9", topic: "m9", at: 6, by: "me") })
        let (backend, exchange) = try await Self.connected([topic, topic, reply, reply])
        func sent(_ path: String) -> [Data] { exchange.requests.filter { $0.url?.path == path }.map(Self.body) }
        for _ in 0..<2 { _ = try await backend.send(MessageDraft(text: "hi", localID: "local-1"), to: "dm/a", thread: nil) }
        for _ in 0..<2 { _ = try await backend.send(MessageDraft(text: "re", localID: "local-2"), to: "dm/a", thread: "dm/a/m9/m9") }
        let topics = try sent("/api/create_topic").map { try Dynamite_CreateTopicRequest(serializedBytes: $0).topicAndMessageID }
        let replies = try sent("/api/create_message").map { try Dynamite_CreateMessageRequest(serializedBytes: $0).messageID }
        #expect(topics.count == 2 && topics[0] == topics[1] && topics[0].count == 11)   // a retry is deduped by Google, not posted twice
        #expect(replies.count == 2 && replies[0] == replies[1] && replies[0] != topics[0])
    }
}

extension AuthTests {
    @Test func editReplacesTextAndKeepsThread() async throws {
        var edited = Self.message("h1", topic: "t1", at: 1, by: "me"); edited.textBody = "new"; edited.lastEditTime = 2
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_EditMessageResponse.with { $0.message = edited })])
        try await backend.edit("space/x/t1/h1", text: "new")
        #expect(exchange.requests.last?.url?.path == "/api/edit_message")
        let message = Self.upserts(await Self.drain(backend)).last
        #expect(message?.id == "space/x/t1/h1" && message?.text == "new" && message?.edited == true)
    }
    @Test func deleteEmitsRemoval() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_DeleteMessageResponse())])
        try await backend.delete("dm/a/t1/m1")
        #expect(exchange.requests.last?.url?.path == "/api/delete_message")
        #expect(await Self.drain(backend).contains(.messageDeleted("dm/a/t1/m1")))
    }
    @Test func reactionTogglesOwnReactionOnLoadedMessage() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_UpdateReactionResponse()), try Self.proto(Dynamite_UpdateReactionResponse())])
        await backend.handle(Self.pushed(.messagePosted, Self.message("h1", topic: "t1", at: 1)))
        try await backend.setReaction("👍", custom: nil, on: "space/x/t1/h1", present: true)
        try await backend.setReaction("👍", custom: nil, on: "space/x/t1/h1", present: false)
        #expect(exchange.requests.filter { $0.url?.path == "/api/update_reaction" }.count == 2)
        let reactions = Self.upserts(await Self.drain(backend)).map(\.reactions)
        #expect(reactions == [[], [Reaction(emoji: "👍", people: ["me"])], []])
    }
    @Test func reactionOnUnknownMessageStillSendsRPC() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_UpdateReactionResponse())])
        try await backend.setReaction("🎉", custom: nil, on: "dm/a/t9/m9", present: true)
        #expect(exchange.requests.last?.url?.path == "/api/update_reaction")
        #expect(Self.upserts(await Self.drain(backend)).isEmpty)
    }
}

extension AuthTests {
    @Test func sharedLinksComeFromListAttachmentsAndPageFromTheLastItem() async throws {
        func item(_ url: String, message: String) -> Dynamite_AttachmentItem {
            .with { i in
                i.annotation.urlMetadata.url.url = url
                i.annotation.urlMetadata.title = ""   // no preview: still listed
                i.messageID.parentID.topicID.topicID = "t-\(message)"
                i.messageID.messageID = message
                i.createTime = 1_700_000_000_000_000
                i.creator.id = "u2"
            }
        }
        let first = Dynamite_ListAttachmentsResponse.with { r in
            r.results = [.with { $0.category = .link; $0.items = (0..<20).map { item("https://example.com/\($0)", message: "m\($0)") } }]
        }
        let members = Dynamite_GetMembersResponse.with { $0.memberProfiles = [.with { $0.member.user.userID.id = "u2"; $0.member.user.name = "Alex" }] }
        let (backend, exchange) = try await Self.connected([try Self.proto(first), try Self.proto(members), try Self.proto(Dynamite_ListAttachmentsResponse())])
        let page = try await backend.shared(.links, in: "space/s", after: nil)
        #expect(page.items.count == 20 && page.hasMore)
        #expect(page.items[0].attachment.kind == .link && page.items[0].attachment.name == "example.com" && page.items[0].sender == "Alex")
        #expect(page.items[19].messageID == "space/s/t-m19/m19")
        let sent = try Dynamite_ListAttachmentsRequest(serializedBytes: Self.body(try #require(exchange.requests.first { $0.url?.path == "/api/list_attachments" })))
        #expect(sent.categories == [.link] && sent.pageSize == 20 && sent.direction == 1 && sent.includeAnchor && !sent.hasAnchor)
        let next = try await backend.shared(.links, in: "space/s", after: page.items.last)
        #expect(next.items.isEmpty && !next.hasMore)
        let paged = try Dynamite_ListAttachmentsRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(paged.anchor.messageID == "m19" && paged.anchor.parentID.topicID.topicID == "t-m19" && !paged.includeAnchor)
    }
    @Test func reactorsComeFromListReactorsWithNamesResolved() async throws {
        let listed = Dynamite_ListReactorsResponse.with { $0.reactors = ["u2", "me", ""].map { id in .with { $0.id = id } } }
        let members = Dynamite_GetMembersResponse.with { $0.memberProfiles = [.with { $0.member.user.userID.id = "u2"; $0.member.user.name = "Alex" }] }
        let (backend, exchange) = try await Self.connected([try Self.proto(listed), try Self.proto(members)])
        let people = try await backend.reactors(of: "space/s/t1/m1", emoji: "👍", custom: nil)
        #expect(people.map(\.name) == ["Alex", "Dave"])
        let sent = try Dynamite_ListReactorsRequest(serializedBytes: Self.body(try #require(exchange.requests.first { $0.url?.path == "/api/list_reactors" })))
        #expect(sent.messageID.messageID == "m1" && sent.messageID.parentID.topicID.topicID == "t1")
        #expect(sent.emoji.unicode == "👍" && sent.pageSize == 100 && sent.hasRequestHeader)
    }
    @Test func searchMapsResultsAndCursor() async throws {
        var hit = Self.message("m1", topic: "t1", at: 3)
        hit.id.parentID.topicID.groupID.dmID.dmID = "zz"   // a conversation not in the sidebar
        let response = Dynamite_SearchMessagesV2Response.with { $0.cursor = "next"; $0.results.items = [.with { $0.message = hit }, .with { _ in }] }
        let (backend, exchange) = try await Self.connected([try Self.proto(response)])
        let page = try await backend.searchMessages("hello", cursor: nil)
        #expect(page.messages.map(\.id) == ["dm/zz/t1/m1"] && page.messages[0].conversationID == "dm/zz")
        #expect(page.cursor == "next")
        #expect(exchange.requests.last?.url?.path == "/api/search_messages_v2")
    }
}

extension AuthTests {
    /// URLProtocol sees the body as a stream; read it back for assertions.
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        return data
    }
    private static func page(_ topics: [(String, Int64)], first: Bool = false) throws -> StubExchange.Reply {
        try proto(Dynamite_ListTopicsResponse.with { r in
            r.topics = topics.map { id, sort in .with { $0.sortTime = sort; $0.replies = [message(id, topic: id, at: sort)] } }
            r.containsFirstTopic = first
        })
    }
    @Test func olderPagingRestartsAfterReload() async throws {
        let recent = try Self.page([("t3", 300), ("t2", 200)])
        let (backend, exchange) = try await Self.connected([recent, try Self.page([("t1", 100)]), recent, try Self.page([("t1", 100)])])
        _ = try await backend.messages(in: "dm/a", thread: nil, before: nil)
        _ = try await backend.messages(in: "dm/a", thread: nil, before: .now)
        _ = try await backend.messages(in: "dm/a", thread: nil, before: nil)   // reselect / resync
        _ = try await backend.messages(in: "dm/a", thread: nil, before: .now)
        let last = try #require(exchange.requests.last { $0.url?.path == "/api/list_topics" })
        #expect(try Dynamite_ListTopicsRequest(serializedBytes: Self.body(last)).filter.olderThan == 200)
    }
    @Test func olderPageWithNothingOlderStops() async throws {
        let (backend, exchange) = try await Self.connected([try Self.page([("t3", 300), ("t2", 200)]), try Self.page([("t2", 200)])])
        _ = try await backend.messages(in: "dm/a", thread: nil, before: nil)
        #expect(!(try await backend.messages(in: "dm/a", thread: nil, before: .now)).hasMore)
        _ = try await backend.messages(in: "dm/a", thread: nil, before: .now)
        #expect(exchange.requests.filter { $0.url?.path == "/api/list_topics" }.count == 2)
    }
    @Test func searchHitOnReplyPointsAtItsThread() async throws {
        var reply = Self.message("r1", topic: "t1", at: 3); reply.id.parentID.topicID.groupID.dmID.dmID = "zz"
        var head = Self.message("t2", topic: "t2", at: 4); head.id.parentID.topicID.groupID.dmID.dmID = "zz"
        let response = Dynamite_SearchMessagesV2Response.with { $0.results.items = [.with { $0.message = reply }, .with { $0.message = head }] }
        let (backend, _) = try await Self.connected([try Self.proto(response)])
        let page = try await backend.searchMessages("x", cursor: nil)
        #expect(page.messages.map(\.threadID) == ["dm/zz/t1/t1", nil])
    }
    @Test func editingAReplyInAnUnloadedThreadKeepsItInTheThread() async throws {
        var edited = Self.message("r1", topic: "t1", at: 2, by: "me"); edited.textBody = "new"
        let (backend, _) = try await Self.connected([try Self.proto(Dynamite_EditMessageResponse.with { $0.message = edited })])
        try await backend.edit("space/x/t1/r1", text: "new")
        #expect(Self.upserts(await Self.drain(backend)).last?.threadID == "space/x/t1/t1")
    }
}

extension AuthTests {
    @Test func unloadedThreadFetchesNewestReplies() async throws {
        let newest = Dynamite_ListMessagesResponse.with {
            $0.messages = [Self.message("t1", topic: "t1", at: 1), Self.message("r1", topic: "t1", at: 2)]
            $0.containsFirstMessage = true
        }
        let (backend, exchange) = try await Self.connected([try Self.proto(newest)])
        let page = try await backend.messages(in: "dm/zz", thread: "dm/zz/t1/t1", before: nil)
        #expect(page.messages.map(\.id) == ["dm/zz/t1/r1"] && !page.hasMore)
        let request = try Dynamite_ListMessagesRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(request.filter.olderThan == 9_007_199_254_740_991)
    }
}

extension AuthTests {
    @Test func historyRequestsTopicMetadataAndUsesTheRealReplyCount() async throws {
        let topics = Dynamite_ListTopicsResponse.with {
            $0.topics = [.with { $0.sortTime = 3; $0.replies = [Self.message("t1", topic: "t1", at: 1), Self.message("r1", topic: "t1", at: 2)]; $0.topicReadState.replySummary.totalReplyCount = 41 }]
        }
        let (backend, exchange) = try await Self.connected([try Self.proto(topics)])
        let page = try await backend.messages(in: "space/x", thread: nil, before: nil)
        #expect(page.messages[0].replyCount == 41)
        let request = try Dynamite_ListTopicsRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(request.fetchOptions == [.topicMetadata, .readReceipts])
    }
}

extension AuthTests {
    @Test func openingAThreadShowsItsNewestRepliesNotTheOldestUnread() async throws {
        // list_topics returns the OLDEST 20 unread replies (r1…r20) of a 41-reply thread.
        let topics = Dynamite_ListTopicsResponse.with {
            $0.topics = [.with {
                $0.sortTime = 41
                $0.replies = [Self.message("t1", topic: "t1", at: 0)] + (1...20).map { Self.message("r\($0)", topic: "t1", at: Int64($0)) }
                $0.topicReadState.replySummary.totalReplyCount = 41
            }]
        }
        let newest = Dynamite_ListMessagesResponse.with { $0.messages = (12...41).map { Self.message("r\($0)", topic: "t1", at: Int64($0)) } }
        let older = Dynamite_ListMessagesResponse.with { $0.messages = (1...12).map { Self.message("r\($0)", topic: "t1", at: Int64($0)) }; $0.containsFirstMessage = true }
        let (backend, exchange) = try await Self.connected([try Self.proto(topics), try Self.proto(newest), try Self.proto(older)])
        _ = try await backend.messages(in: "space/x", thread: nil, before: nil)
        let opened = try await backend.messages(in: "space/x", thread: "space/x/t1/t1", before: nil)
        #expect(opened.messages.last?.id == "space/x/t1/r41" && opened.messages.first?.id == "space/x/t1/r12" && opened.hasMore)
        let opening = try Dynamite_ListMessagesRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(opening.filter.olderThan == 9_007_199_254_740_991)
        let page = try await backend.messages(in: "space/x", thread: "space/x/t1/t1", before: .now)
        #expect(page.messages.map(\.id) == (1...11).map { "space/x/t1/r\($0)" } && !page.hasMore)
        #expect(try Dynamite_ListMessagesRequest(serializedBytes: Self.body(try #require(exchange.requests.last))).filter.olderThan == 12)
    }
}

extension AuthTests {
    /// A send whose first attempt reached the server: the retry's id is taken, but the message is already here, so it counts as sent.
    @Test func aRetryOfAMessageTheServerAlreadyHasSucceeds() async throws {
        let id = DynamiteID.messageID(for: "local-1"), reply = DynamiteID.messageID(for: "local-2")
        let history = try Self.proto(Dynamite_ListTopicsResponse.with { $0.topics = [.with { $0.replies = [Self.message(id, topic: id, at: 5, by: "me")] }] })
        let replies = try Self.proto(Dynamite_ListMessagesResponse.with { $0.messages = [Self.message(reply, topic: id, at: 6, by: "me")] })
        let (backend, _) = try await Self.connected([history, .init(status: 400), replies, .init(status: 400)])
        _ = try await backend.messages(in: "dm/a", thread: nil, before: nil)
        let sent = try await backend.send(MessageDraft(text: id, localID: "local-1"), to: "dm/a", thread: nil)
        #expect(sent.id == DynamiteID.message("dm/a", topic: id, message: id))
        _ = try await backend.messages(in: "dm/a", thread: sent.id, before: nil)
        let sentReply = try await backend.send(MessageDraft(text: reply, localID: "local-2"), to: "dm/a", thread: sent.id)
        #expect(sentReply.id == DynamiteID.message("dm/a", topic: id, message: reply) && sentReply.threadID == sent.id)
    }
}

extension AuthTests {
    /// Others see our read receipt from this time, which they compare with server create times, so it is the newest
    /// message's time rather than the Mac's clock, and it never moves back.
    @Test func markReadSendsTheNewestMessageTimeAndNeverGoesBack() async throws {
        let history = try Self.proto(Dynamite_ListTopicsResponse.with { $0.topics = [
            .with { $0.replies = [Self.message("a", topic: "a", at: 1_700_000_000_000_001, by: "u1")] },
            .with { $0.replies = [Self.message("b", topic: "b", at: 1_700_000_000_000_009, by: "u1"),
                                  Self.message("c", topic: "b", at: 1_700_000_000_000_042, by: "u1")] }] })
        let older = try Self.proto(Dynamite_ListTopicsResponse.with { $0.topics = [.with { $0.replies = [Self.message("z", topic: "z", at: 7, by: "u1")] }] })
        let done = try Self.proto(Dynamite_MarkGroupReadstateResponse())
        let (backend, exchange) = try await Self.connected([history, done, older, done])
        _ = try await backend.messages(in: "dm/a", thread: nil, before: nil)
        try await backend.markRead("dm/a")
        _ = try await backend.messages(in: "dm/a", thread: nil, before: nil)   // a reload that only holds an older message
        try await backend.markRead("dm/a")
        let sent = try exchange.requests.filter { $0.url?.path == "/api/mark_group_readstate" }
            .map { try Dynamite_MarkGroupReadstateRequest(serializedBytes: Self.body($0)).lastReadTime }
        #expect(sent == [1_700_000_000_000_042, 1_700_000_000_000_042])
    }
}

extension AuthTests {
    /// Replying from a search hit, whose thread head was never loaded: the reply must not be taken for the head,
    /// or the next reply would be filed under it and pushed as a bumped head.
    @Test func replyingInAnUnloadedThreadDoesNotMakeTheReplyItsHead() async throws {
        let first = Dynamite_CreateMessageResponse.with { $0.message = Self.message("r5", topic: "t1", at: 6, by: "me") }
        let second = Dynamite_CreateMessageResponse.with { $0.message = Self.message("r6", topic: "t1", at: 7, by: "me") }
        let (backend, _) = try await Self.connected([try Self.proto(first), try Self.proto(second)])
        _ = try await backend.send(MessageDraft(text: "r5", localID: "local-5"), to: "space/x", thread: "space/x/t1/t1")
        let reply = try await backend.send(MessageDraft(text: "r6", localID: "local-6"), to: "space/x", thread: "space/x/t1/t1")
        #expect(reply.threadID == "space/x/t1/t1")
        #expect(Self.upserts(await Self.drain(backend)).isEmpty)   // no "head" r5 with a bumped reply count
    }
}

extension AuthTests {
    /// Google Chat edits only the text: the message's uploads and Drive files go back unchanged, or the server drops them.
    @Test func editKeepsTheMessagesAttachments() async throws {
        let upload = Dynamite_Annotation.with { $0.type = .uploadMetadata; $0.uploadMetadata.attachmentToken = "tok"; $0.uploadMetadata.contentType = "image/png" }
        let drive = Dynamite_Annotation.with { $0.type = .driveFile; $0.driveMetadata.id = "d1"; $0.driveMetadata.title = "Plan" }
        let bold = Dynamite_Annotation.with { $0.type = .formatData; $0.startIndex = 0; $0.length = 5; $0.formatMetadata.formatType = .bold }
        let link = Dynamite_Annotation.with { $0.type = .url; $0.startIndex = 6; $0.length = 5; $0.urlMetadata.url.url = "https://world.example" }
        var original = Self.message("h1", topic: "t1", at: 1, by: "me")
        original.textBody = "hello world"; original.annotations = [bold, upload, link, drive]
        var edited = original; edited.textBody = "hello there"; edited.lastEditTime = 2
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_EditMessageResponse.with { $0.message = edited })])
        await backend.handle(Self.pushed(.messagePosted, original))
        try await backend.edit("space/x/t1/h1", text: "hello there", formatting: [TextStyleRange(style: .italic, start: 6, length: 5)])
        let request = try Dynamite_EditMessageRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(request.textBody == "hello there")
        #expect(request.annotations == DynamiteMapper.annotations([TextStyleRange(style: .italic, start: 6, length: 5)]) + [upload, drive])
        #expect(request.messageInfo.acceptFormatAnnotations)
    }
    /// A link the message already has comes back into the composer as a link: it goes back as its own annotation, once;
    /// a link added while editing goes as a new one.
    @Test func editSendsAnExistingLinkOnceAndANewOne() async throws {
        let old = Dynamite_Annotation.with { $0.type = .url; $0.startIndex = 0; $0.length = 5; $0.urlMetadata.url.url = "https://hello.example" }
        var original = Self.message("h1", topic: "t1", at: 1, by: "me"); original.textBody = "hello world"; original.annotations = [old]
        var edited = original; edited.lastEditTime = 2
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_EditMessageResponse.with { $0.message = edited })])
        await backend.handle(Self.pushed(.messagePosted, original))
        let added = URL(string: "https://world.example")!
        try await backend.edit("space/x/t1/h1", text: "hello world", formatting: [TextStyleRange(style: .link(URL(string: "https://hello.example")!), start: 0, length: 5),
                                                                              TextStyleRange(style: .link(added), start: 6, length: 5)])
        let request = try Dynamite_EditMessageRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(request.annotations == [DynamiteMapper.link(added, 6, 5), old])
    }
    @Test func editOfAnUnloadedMessageSendsOnlyItsText() async throws {
        var edited = Self.message("h1", topic: "t1", at: 1, by: "me"); edited.textBody = "new"
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_EditMessageResponse.with { $0.message = edited })])
        try await backend.edit("space/x/t1/h1", text: "new")
        let request = try Dynamite_EditMessageRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(request.textBody == "new" && request.annotations.isEmpty && !request.messageInfo.acceptFormatAnnotations)
    }
}

extension AuthTests {
    /// Google names someone a placeholder until they accept a DM; their first live message brings their real profile.
    private static func pushedDM(_ message: Dynamite_Message) -> Dynamite_StreamEventsResponse {
        .with { $0.event.groupID.dmID.dmID = "d"; $0.event.bodies = [.with { $0.eventType = .messagePosted; $0.messagePosted.message = message }] }
    }
    @Test func aSendersFirstLiveMessageRefreshesTheirProfile() async throws {
        let anonymous = Dynamite_GetMembersResponse.with { $0.memberProfiles = [.with { $0.member.user.userID.id = "u2"; $0.member.user.name = "Anonymous User" }] }
        let named = Dynamite_GetMembersResponse.with { $0.memberProfiles = [.with { $0.member.user.userID.id = "u2"; $0.member.user.name = "Dariel" }] }
        let listed = Dynamite_ListReactorsResponse.with { $0.reactors = [.with { $0.id = "u2" }] }
        let (backend, exchange) = try await Self.connected([try Self.proto(listed), try Self.proto(anonymous), try Self.proto(named)])
        _ = try await backend.reactors(of: "space/s/t1/m1", emoji: "👍", custom: nil)   // u2 known, as the placeholder
        await backend.handle(Self.pushedDM(Self.message("m2", topic: "m2", at: 5, by: "u2")))
        await backend.handle(Self.pushedDM(Self.message("m3", topic: "m3", at: 6, by: "u2")))
        let events = await Self.drain(backend)
        #expect(events.contains(.resync))
        #expect(Self.upserts(events).map(\.sender.name) == ["Dariel", "Dariel"])
        #expect(exchange.requests.filter { $0.url?.path == "/api/get_members" }.count == 3)   // connect, the reactors, one re-read: not per message
    }
}

struct RequestHeaderTests {
    /// Google switches off every capability a declared list leaves out (a list of 17 alone dropped forwards, group DM
    /// names and Ask Gemini), so every RPC declares web's whole list, each field FULLY_SUPPORTED (2).
    @Test func everyRequestDeclaresWebsWholeCapabilityList() throws {
        let caps = try Dynamite_ClientFeatureCapabilities(serializedBytes: try DynamiteClient.header.clientFeatureCapabilities.serializedBytes() as Data)
        var declared: [Int: UInt64] = [:]
        var bytes = Array(try caps.serializedBytes() as Data)[...]
        func varint() -> UInt64 { var v: UInt64 = 0, shift: UInt64 = 0; while let b = bytes.popFirst() { v |= UInt64(b & 0x7F) << shift; if b < 0x80 { break }; shift += 7 }; return v }
        while !bytes.isEmpty { let key = varint(); declared[Int(key >> 3)] = varint() }
        #expect(declared.keys.sorted() == DynamiteClient.webCapabilities)
        #expect(declared.values.allSatisfy { $0 == 2 })
        #expect(DynamiteClient.webCapabilities.count == 48 && DynamiteClient.webCapabilities.contains(17) && DynamiteClient.webCapabilities.contains(53))
        #expect(DynamiteClient.header.clientType == .web && DynamiteClient.header.traceID == 0)
    }
}

extension AuthTests {
    /// As Google Chat sends it: field 11 = 2. Without it, list_topics on the Ask Gemini DM fails (HTTP 500) once
    /// capabilities 6 and 17 are declared.
    @Test func listTopicsSendsField11AsGoogleChatDoes() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_ListTopicsResponse.with { $0.containsFirstTopic = true })])
        _ = try await backend.messages(in: "dm/gemini", thread: nil, before: nil)
        let sent = try Dynamite_ListTopicsRequest(serializedBytes: Self.body(try #require(exchange.requests.first { $0.url?.path == "/api/list_topics" })))
        #expect(sent.field11 == 2)
    }
}
