import Foundation
import SwiftProtobuf
import Testing
@testable import Parley

/// Typing, receipts and presence through the backend, network-stubbed.
extension AuthTests {
    private static func event(_ type: Dynamite_EventBody.EventType, space: String = "x", _ fill: (inout Dynamite_EventBody) -> Void) -> Dynamite_StreamEventsResponse {
        .with { $0.event.groupID.spaceID.spaceID = space; $0.event.bodies = [.with { $0.eventType = type; fill(&$0) }] }
    }
    private static func typing(_ user: String, _ state: Dynamite_TypingState = .typing, topic: String? = nil) -> Dynamite_StreamEventsResponse {
        event(.typingStateChanged) { b in
            b.typingStateChanged.state = state
            b.typingStateChanged.userID.id = user
            if let topic { b.typingStateChanged.context.topicID.topicID = topic; b.typingStateChanged.context.topicID.groupID.spaceID.spaceID = "x" }
            else { b.typingStateChanged.context.groupID.spaceID.spaceID = "x" }
        }
    }
    private static func receipts(_ reads: [(String, Int64)], enabled: Bool?) -> Dynamite_ReadReceiptSet {
        .with { set in
            if let enabled { set.enabled = enabled }
            set.readReceipts = reads.map { user, time in .with { $0.user.userID.id = user; $0.lastReadTimestampMicros = time } }
        }
    }
    private static func requests<R: SwiftProtobuf.Message>(_ exchange: StubExchange, _ path: String) throws -> [R] {
        try exchange.requests.filter { $0.url?.path == "/api/\(path)" }.map { try R(serializedBytes: Self.body($0)) }
    }

    @Test func typingTargetsTheGroupOrTheThreadsTopic() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_SetTypingStateResponse()), try Self.proto(Dynamite_SetTypingStateResponse())])
        try await backend.sendTyping(conversation: "dm/a", thread: nil)
        try await backend.sendTyping(conversation: "dm/a", thread: "dm/a/t1/t1")
        let sent: [Dynamite_SetTypingStateRequest] = try Self.requests(exchange, "set_typing_state")
        #expect(sent.map(\.state) == [.typing, .typing])
        #expect(sent[0].context.groupID.dmID.dmID == "a" && sent[0].hasRequestHeader)
        #expect(sent[1].context.topicID.topicID == "t1" && sent[1].context.topicID.groupID.dmID.dmID == "a")
    }
    @Test func pushedTypingNamesTheTypistAndDropsOurOwn() async throws {
        let (backend, _) = try await Self.connected()
        await backend.handle(Self.typing("u1"))
        await backend.handle(Self.typing("me"))
        await backend.handle(Self.typing("u1", topic: "t1"))
        await backend.handle(Self.typing("u1", .stopped))
        let events = await Self.drain(backend).filter { if case .typingChanged = $0 { true } else { false } }
        #expect(events == [.typingChanged("space/x", nil, "u1", isTyping: true), .typingChanged("space/x", "space/x/t1/t1", "u1", isTyping: true),
                           .typingChanged("space/x", nil, "u1", isTyping: false)])
    }
    @Test func pushedReceiptsMapReadersToTimesWithoutUs() async throws {
        let (backend, _) = try await Self.connected()
        await backend.handle(Self.event(.readReceiptChanged) { b in
            b.readReceiptChanged.groupID.dmID.dmID = "a"
            b.readReceiptChanged.readReceiptSet = Self.receipts([("u1", 2_000_000), ("me", 3_000_000)], enabled: true)
        })
        await backend.handle(Self.event(.readReceiptChanged) { $0.readReceiptChanged.readReceiptSet = Self.receipts([("u1", 4_000_000)], enabled: nil) })
        let events = await Self.drain(backend).filter { if case .readReceiptsChanged = $0 { true } else { false } }
        #expect(events == [.readReceiptsChanged("dm/a", ["u1": Date(timeIntervalSince1970: 2)], enabled: true),
                           .readReceiptsChanged("space/x", ["u1": Date(timeIntervalSince1970: 4)], enabled: nil)])
    }
    @Test func historyAsksForReceiptsAndEmitsThem() async throws {
        let topics = Dynamite_ListTopicsResponse.with { $0.readReceiptSet = Self.receipts([("u1", 1_000_000)], enabled: true) }
        let (backend, exchange) = try await Self.connected([try Self.proto(topics)])
        _ = try await backend.messages(in: "dm/a", thread: nil, before: nil)
        let request: [Dynamite_ListTopicsRequest] = try Self.requests(exchange, "list_topics")
        #expect(request.first?.fetchOptions == [.topicMetadata, .readReceipts])
        #expect(await Self.drain(backend).contains(.readReceiptsChanged("dm/a", ["u1": Date(timeIntervalSince1970: 1)], enabled: true)))
    }
    @Test func pushedStatusCarriesDoNotDisturbAndCustomStatus() async throws {
        let (backend, _) = try await Self.connected()
        await backend.handle(Self.event(.userStatusUpdatedEvent) { b in
            b.userStatusUpdated.userStatus.userID.id = "u1"
            b.userStatusUpdated.userStatus.dndSettings.dndState = .dnd
            b.userStatusUpdated.userStatus.customStatus.statusText = "Lunch"
            b.userStatusUpdated.userStatus.customStatus.emoji.unicode = "🥪"
        })
        await backend.handle(Self.event(.userStatusUpdatedEvent) { $0.userStatusUpdated.userStatus.userID.id = "u2" })
        let events = await Self.drain(backend).filter { if case .presenceChanged = $0 { true } else { false } }
        #expect(events == [.presenceChanged("u1", .doNotDisturb, status: "🥪 Lunch"), .presenceChanged("u2", nil, status: nil)])
    }
    @Test func presenceIsOneBatchedRequestWithoutUs() async throws {
        let response = Dynamite_GetUserPresenceResponse.with {
            $0.userPresences = [.with { $0.userID.id = "u1"; $0.presence = .active; $0.userStatus.customStatus.statusText = "Here" },
                                .with { $0.userID.id = "u2"; $0.presence = .presence3 },
                                .with { $0.userID.id = "u3"; $0.presence = .active; $0.dndState = .dnd }]
        }
        let (backend, exchange) = try await Self.connected([try Self.proto(response)])
        try await backend.fetchPresence(["u1", "me", "u2", "u3"])
        let sent: [Dynamite_GetUserPresenceRequest] = try Self.requests(exchange, "get_user_presence")
        #expect(sent.count == 1 && sent[0].userIds.map(\.id) == ["u1", "u2", "u3"])
        let events = await Self.drain(backend).filter { if case .presenceChanged = $0 { true } else { false } }
        #expect(events == [.presenceChanged("u1", .available, status: "Here"), .presenceChanged("u2", .away, status: nil),
                           .presenceChanged("u3", .doNotDisturb, status: nil)])
    }
    @Test(.timeLimit(.minutes(1))) func typingIsWatchedForSubscribedConversations() async throws {
        let block = #"["dfe.cr.rr",["r"],[null,[null,"/punctual/prod-dynamite-prod-02-us/user-targeted-changes",[]],[1,0],[3600],"U","K"],1]"#
        let bootstrap = StubExchange.Reply(data: Data((#"{"SMqcke":"test-xsrf"} "# + block).utf8))
        let vault = MemoryVault()
        vault.write(try JSONEncoder().encode(WebCredentials(cookies: [SessionCookie(name: "SID", value: "s", domain: ".google.com", path: "/", secure: true, expires: -1)], userAgent: "T")))
        let exchange = StubExchange([bootstrap, .init(data: Data(#"["G",1]"#.utf8)), .init(data: Data("29\n[[0,[\"c\",\"S\",\"\",8,15,30000]]]".utf8))])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        let channel = PunctualChannel(authorizer: auth, config: .init(backoff: { _ in .seconds(3600) }), onEvent: { _ in }, onState: { _ in })
        await channel.subscribe(["dm/a", "space/b"])
        let run = Task { await channel.run() }
        while exchange.requests.count < 4 { try await Task.sleep(for: .milliseconds(10)) }
        run.cancel(); await run.value
        let open = try #require(exchange.requests.first { $0.url?.path.hasSuffix("/multi-watch/channel") == true && $0.httpMethod == "POST" })
        let form = String(decoding: Self.body(open), as: UTF8.self).removingPercentEncoding ?? ""
        #expect(form.contains(#"[["group-state-changes"],[1],[[["state"],["group"],["a"],["typing"]]]]"#))
        #expect(form.contains(#"[["group-state-changes"],[1],[[["state"],["group"],["b"],["typing"]]]]"#))
    }
}
