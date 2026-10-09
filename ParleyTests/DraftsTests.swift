import Foundation
import SwiftProtobuf
import Testing
@testable import Parley

/// Protobuf wire bytes assembled by hand, to pin nesting that a proto built and parsed by the same schema can't catch.
enum Wire {
    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value, out: [UInt8] = []
        repeat { var byte = UInt8(value & 0x7F); value >>= 7; if value != 0 { byte |= 0x80 }; out.append(byte) } while value != 0
        return out
    }
    static func int(_ field: Int, _ value: UInt64) -> [UInt8] { varint(UInt64(field << 3)) + varint(value) }
    static func ld(_ field: Int, _ bytes: [UInt8]) -> [UInt8] { varint(UInt64(field << 3 | 2)) + varint(UInt64(bytes.count)) + bytes }
    static func str(_ field: Int, _ text: String) -> [UInt8] { ld(field, Array(text.utf8)) }
}

/// Server drafts on the wire, in the shapes Google Chat's web client sends and receives (ids made up).
extension AuthTests {
    static let header = Array(try! DynamiteClient.header.serializedBytes() as Data)   // RequestHeader as every RPC sends it
    static let group = Wire.ld(2, Wire.ld(1, Wire.str(1, "AAQAexample")))     // UnsentMessageId.2 GroupId {1 SpaceId {1 id}}
    static func unsentID(_ id: String, topic: String? = nil) -> [UInt8] { Wire.str(1, id) + group + (topic.map { Wire.str(3, $0) } ?? []) }
    static func body(_ exchange: StubExchange, _ path: String) throws -> [UInt8] {
        [UInt8](Self.body(try #require(exchange.requests.last { $0.url?.path == "/api/\(path)" })))
    }

    /// create_unsent_message: {1 header, 2 UnsentMessage {1 id {1, 2 group}, 4 text, 7 DRAFT, 9 mutation id}}.
    @Test func aCreateRequestInTheCapturedShapeDecodes() throws {
        let bytes = Wire.ld(1, Self.header) + Wire.ld(2, Wire.ld(1, Self.unsentID("dRaFt0000a1")) + Wire.str(4, "draft test") + Wire.int(7, 2)
                                                        + Wire.str(9, "0F0F0F0F-1111-4222-8333-444455556666"))
        let request = try Dynamite_CreateUnsentMessageRequest(serializedBytes: bytes)
        #expect(request.requestHeader.clientType == .web)
        let draft = request.unsentMessage
        #expect(draft.id.id == "dRaFt0000a1" && draft.id.groupID.spaceID.spaceID == "AAQAexample" && !draft.id.hasTopicID)
        #expect(draft.textBody == "draft test" && draft.type == .draft && draft.mutationID == "0F0F0F0F-1111-4222-8333-444455556666")
        #expect(try request.serializedBytes() as [UInt8] == bytes)
    }
    /// update_unsent_message: the same id, the whole text, a new mutation id, and the mask {2: packed [9, 4, 5, 6]}; no type.
    @Test func anUpdateRequestWithItsMaskDecodes() throws {
        let bytes = Wire.ld(1, Self.header) + Wire.ld(2, Wire.ld(1, Self.unsentID("dRaFt0000a1")) + Wire.str(4, "update test more")
                                                        + Wire.str(9, "1A1A1A1A-2222-4333-8444-555566667777"))
            + Wire.ld(3, Wire.ld(2, [9, 4, 5, 6]))
        let request = try Dynamite_UpdateUnsentMessageRequest(serializedBytes: bytes)
        #expect(request.unsentMessage.id.id == "dRaFt0000a1" && request.unsentMessage.textBody == "update test more" && !request.unsentMessage.hasType)
        #expect(request.updateMask.fields == [9, 4, 5, 6])
        #expect(try request.serializedBytes() as [UInt8] == bytes)
    }
    /// A list reply's thread draft: id.3 is the topic id, and the times are Timestamp {seconds, nanos}.
    static let threadDraft = Wire.ld(1, unsentID("dRaFt0000b2", topic: "tOpIc0000b2"))
        + Wire.ld(2, Wire.int(1, 1_791_423_754) + Wire.int(2, 179_982_000)) + Wire.ld(3, Wire.int(1, 1_791_423_754) + Wire.int(2, 179_982_000))
        + Wire.str(4, "thread draft") + Wire.int(7, 2) + Wire.str(9, "2B2B2B2B-3333-4444-8555-666677778888")
    @Test func aListedThreadDraftDecodesWithItsTopic() throws {
        let reply = Wire.ld(1, Self.threadDraft) + Wire.ld(2, Wire.str(1, "1791423754179982"))   // revision (2) is not used
        let response = try Dynamite_ListUnsentMessagesResponse(serializedBytes: reply)
        let draft = try #require(response.unsentMessages.first.flatMap(DynamiteMapper.draft))
        #expect(draft.id == "dRaFt0000b2" && draft.conversationID == "space/AAQAexample")
        #expect(draft.threadID == "space/AAQAexample/tOpIc0000b2/tOpIc0000b2" && draft.text == "thread draft")
        #expect(abs(draft.updatedAt.timeIntervalSince1970 - 1_791_423_754.179982) < 0.001)
    }
    @Test func scheduledMessagesAreNoDrafts() {
        let scheduled = Dynamite_UnsentMessage.with { $0.id.id = "s"; $0.id.groupID.spaceID.spaceID = "x"; $0.type = .scheduled }
        #expect(DynamiteMapper.draft(scheduled) == nil)
    }
    /// A send that was a draft names it in MessageInfo.5, as Google Chat's web client does: {1 accept, 5 UnsentMessageId}.
    @Test func messageInfoNamesTheDraftAtFieldFive() throws {
        let bytes = Wire.int(1, 1) + Wire.ld(5, Wire.str(1, "dRaFt0000c3") + Wire.ld(2, Wire.ld(3, Wire.str(1, "dmExample01"))))
        let info = try Dynamite_MessageInfo(serializedBytes: bytes)
        #expect(info.unsentMessageID.id == "dRaFt0000c3" && info.unsentMessageID.groupID.dmID.dmID == "dmExample01")
    }

    @Test func listingAsksForDraftsAndMapsThePage() async throws {
        let reply = StubExchange.Reply(headers: ["Content-Type": "application/x-protobuf"], data: Data(Wire.ld(1, Self.threadDraft)))
        let (backend, exchange) = try await Self.connected([reply])
        let drafts = try await backend.drafts()
        #expect(drafts.map(\.id) == ["dRaFt0000b2"])
        // {1 header, 2 paging (empty), 3 filter {3 DRAFT, 5 0}}
        #expect(try Self.body(exchange, "list_unsent_messages") == Wire.ld(1, Self.header) + Wire.ld(2, []) + Wire.ld(3, Wire.int(3, 2) + Wire.int(5, 0)))
    }
    @Test func savingCreatesThenUpdatesInTheCapturedShapes() async throws {
        let created = Dynamite_CreateUnsentMessageResponse.with { $0.unsentMessage.updateTime = .with { $0.seconds = 1_791_423_708 } }
        let updated = Dynamite_UpdateUnsentMessageResponse.with { $0.unsentMessage.updateTime = .with { $0.seconds = 1_791_423_990 } }
        let (backend, exchange) = try await Self.connected([try Self.proto(created), try Self.proto(updated)])
        var draft = try await backend.saveDraft(ServerDraft(conversationID: "space/AAQAexample", text: "draft test"))
        #expect(draft.id.count == 11 && draft.updatedAt == Date(timeIntervalSince1970: 1_791_423_708))
        let create = try Dynamite_CreateUnsentMessageRequest(serializedBytes: Self.body(exchange, "create_unsent_message"))
        let mutation = create.unsentMessage.mutationID
        #expect(mutation == mutation.uppercased() && UUID(uuidString: mutation) != nil)
        #expect(try Self.body(exchange, "create_unsent_message") == Wire.ld(1, Self.header)
                + Wire.ld(2, Wire.ld(1, Self.unsentID(draft.id)) + Wire.str(4, "draft test") + Wire.int(7, 2) + Wire.str(9, mutation)))

        draft.text = "update test more"
        _ = try await backend.saveDraft(draft)
        let update = try Dynamite_UpdateUnsentMessageRequest(serializedBytes: Self.body(exchange, "update_unsent_message"))
        #expect(update.unsentMessage.mutationID != mutation)
        #expect(try Self.body(exchange, "update_unsent_message") == Wire.ld(1, Self.header)
                + Wire.ld(2, Wire.ld(1, Self.unsentID(draft.id)) + Wire.str(4, "update test more") + Wire.str(9, update.unsentMessage.mutationID))
                + Wire.ld(3, Wire.ld(2, [9, 4, 5, 6])))
    }
    /// A draft written elsewhere can hold what Parley's composer can't edit, such as a space chip: saving it again keeps
    /// the chip, moved with its text when that text appears once in the new draft, and drops it when the text is gone.
    @Test func savingKeepsAChipThisComposerCannotEdit() async throws {
        let chip = Dynamite_Annotation.with { $0.type = .group; $0.startIndex = 0; $0.length = 9; $0.groupMetadata.groupID.spaceID.spaceID = "AAQAexample" }
        let listed = Dynamite_ListUnsentMessagesResponse.with { r in
            r.unsentMessages = [.with { m in
                m.id.id = "dRaFt0000c3"; m.id.groupID.spaceID.spaceID = "AAQAexample"; m.textBody = "Lunchroom"; m.annotations = [chip]; m.type = .draft
            }]
        }
        let ok = try Self.proto(Dynamite_UpdateUnsentMessageResponse())
        let (backend, exchange) = try await Self.connected([try Self.proto(listed), ok, ok, ok])
        var draft = try #require(try await backend.drafts().first)
        draft.text = "Lunchroom soon"
        _ = try await backend.saveDraft(draft)
        var sent = try Dynamite_UpdateUnsentMessageRequest(serializedBytes: Self.body(exchange, "update_unsent_message"))
        #expect(sent.unsentMessage.annotations == [chip])
        draft.text = "Hi Lunchroom soon"
        _ = try await backend.saveDraft(draft)
        sent = try Dynamite_UpdateUnsentMessageRequest(serializedBytes: Self.body(exchange, "update_unsent_message"))
        #expect(sent.unsentMessage.annotations.map(\.startIndex) == [3] && sent.unsentMessage.annotations.first?.groupMetadata == chip.groupMetadata)
        draft.text = "Hi soon"
        _ = try await backend.saveDraft(draft)
        sent = try Dynamite_UpdateUnsentMessageRequest(serializedBytes: Self.body(exchange, "update_unsent_message"))
        #expect(sent.unsentMessage.annotations.isEmpty)
    }
    @Test func sendingADraftKeepsItsChip() async throws {
        let chip = Dynamite_Annotation.with { $0.type = .group; $0.startIndex = 0; $0.length = 9; $0.groupMetadata.groupID.spaceID.spaceID = "AAQAexample" }
        let listed = Dynamite_ListUnsentMessagesResponse.with { r in
            r.unsentMessages = [.with { m in
                m.id.id = "dRaFt0000c3"; m.id.groupID.spaceID.spaceID = "AAQAexample"; m.textBody = "Lunchroom"; m.annotations = [chip]; m.type = .draft
            }]
        }
        let topic = try Self.proto(Dynamite_CreateTopicResponse.with { $0.topic.replies = [Self.message("m9", topic: "m9", at: 5, by: "me")] })
        let (backend, exchange) = try await Self.connected([try Self.proto(listed), topic])
        _ = try await backend.drafts()
        _ = try await backend.send(MessageDraft(text: "Lunchroom", localID: "l1", serverDraftID: "dRaFt0000c3"), to: "space/AAQAexample", thread: nil)
        let sent = try Dynamite_CreateTopicRequest(serializedBytes: Self.body(exchange, "create_topic"))
        #expect(sent.annotations.contains(chip))
    }
    @Test func aThreadDraftIsDeletedByItsFullID() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_DeleteUnsentMessageResponse())])
        try await backend.deleteDraft(ServerDraft(id: "dRaFt0000b2", conversationID: "space/AAQAexample",
                                                  threadID: "space/AAQAexample/tOpIc0000b2/tOpIc0000b2", text: ""))
        #expect(try Self.body(exchange, "delete_unsent_message") == Wire.ld(1, Self.header) + Wire.ld(2, Self.unsentID("dRaFt0000b2", topic: "tOpIc0000b2")))
    }
    @Test func sendingADraftNamesItInMessageInfo() async throws {
        let topic = Dynamite_CreateTopicResponse.with { $0.topic.replies = [Self.message("m9", topic: "m9", at: 5, by: "me")] }
        let reply = Dynamite_CreateMessageResponse.with { $0.message = Self.message("r5", topic: "t1", at: 6, by: "me") }
        let (backend, exchange) = try await Self.connected([try Self.proto(topic), try Self.proto(reply)])
        _ = try await backend.send(MessageDraft(text: "hi", localID: "l1", serverDraftID: "dRaFt0000a1"), to: "space/AAQAexample", thread: nil)
        let created = try Dynamite_CreateTopicRequest(serializedBytes: Self.body(exchange, "create_topic"))
        #expect(try created.messageInfo.unsentMessageID.serializedBytes() as [UInt8] == Self.unsentID("dRaFt0000a1"))
        _ = try await backend.send(MessageDraft(text: "re", localID: "l2", serverDraftID: "dRaFt0000b2"), to: "space/AAQAexample",
                                   thread: "space/AAQAexample/tOpIc0000b2/tOpIc0000b2")
        let replied = try Dynamite_CreateMessageRequest(serializedBytes: Self.body(exchange, "create_message"))
        #expect(try replied.messageInfo.unsentMessageID.serializedBytes() as [UInt8] == Self.unsentID("dRaFt0000b2", topic: "tOpIc0000b2"))
    }
    /// UNSENT_MESSAGE_CREATED / _UPDATED / _DELETED (87–89) carry the draft at event body field 67 {1 UnsentMessage}.
    @Test func pushedDraftEventsBecomeDraftChanges() async throws {
        let (backend, _) = try await Self.connected()
        for type: UInt64 in [87, 89, 88] {
            let body = try Dynamite_EventBody(serializedBytes: Wire.int(12, type) + Wire.ld(67, Wire.ld(1, Self.threadDraft)))
            await backend.handle(.with { $0.event.bodies = [body] })
        }
        let events = await Self.drain(backend).filter { if case .draftChanged = $0 { true } else if case .draftDeleted = $0 { true } else { false } }
        let draft = try #require(DynamiteMapper.draft(try Dynamite_UnsentMessage(serializedBytes: Self.threadDraft)))
        #expect(events == [.draftChanged(draft), .draftChanged(draft), .draftDeleted("dRaFt0000b2")])
    }
}

/// The store's draft sync, against the fake backend, with the pause and idle times shortened.
@MainActor
struct DraftSyncTests {
    static let alex = "alex/timeline", maria = "maria/timeline"
    private func started(server: [ServerDraft] = [], cache: LaunchCache? = nil) async -> (ChatStore, FakeBackend) {
        let fake = FakeBackend()
        await fake.simulateDrafts(server)
        let store = ChatStore(backend: fake, cache: cache)
        store.draftPause = .milliseconds(30); store.draftIdle = .seconds(5)
        await store.start()
        return (store, fake)
    }
    private func until(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        Issue.record("timed out")
    }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }
    private static func cache(_ snapshot: LaunchSnapshot) throws -> LaunchCache {
        let cache = LaunchCache(url: URL.temporaryDirectory.appending(path: "parley-cache-\(UUID().uuidString).json"))
        try cache.save(snapshot)
        return cache
    }

    @Test func aDraftIsCreatedAfterAPauseInTyping() async throws {
        let (store, fake) = await started()
        store.setDraft("hel", conversation: "alex", thread: nil)
        store.setDraft("hello", conversation: "alex", thread: nil)
        #expect(await fake.draftWrites.isEmpty)
        try await until { await fake.draftWrites == ["create alex/timeline"] }
        #expect(store.serverDrafts[Self.alex]?.text == "hello")
    }
    @Test func leavingUpdatesTheDraftOnlyWhenItChanged() async throws {
        let (store, fake) = await started()
        store.setDraft("hello", conversation: "alex", thread: nil)
        try await until { store.serverDrafts[Self.alex] != nil }
        store.setDraft("hello there", conversation: "alex", thread: nil)
        try await settle()
        #expect(await fake.draftWrites == ["create alex/timeline"])   // a pause doesn't update; leaving does
        await store.select("maria")
        try await until { await fake.draftWrites == ["create alex/timeline", "update alex/timeline"] }
        #expect(store.serverDrafts[Self.alex]?.text == "hello there")
        await store.select("alex"); await store.select("maria")
        try await settle()
        #expect(await fake.draftWrites.count == 2)
    }
    @Test func clearingTheComposerDeletesTheDraft() async throws {
        let (store, fake) = await started()
        store.setDraft("hello", conversation: "alex", thread: nil)
        try await until { store.serverDrafts[Self.alex] != nil }
        store.setDraft("", conversation: "alex", thread: nil)
        try await until { await fake.draftWrites.last == "delete alex/timeline" }
        #expect(store.serverDrafts[Self.alex] == nil)
    }
    @Test func aThreadsReplyBoxHasADraftOfItsOwn() async throws {
        let (store, fake) = await started()
        store.setDraft("on it", conversation: "design", thread: "d4")
        try await until { await fake.draftWrites == ["create design/d4"] }
        #expect(store.threadsWithDrafts(in: "design") == ["d4"])
    }
    @Test func sendingNamesTheDraftAndDropsIt() async throws {
        let (store, fake) = await started()
        store.setDraft("hello", conversation: "alex", thread: nil)
        try await until { store.serverDrafts[Self.alex] != nil }
        let id = try #require(store.serverDrafts[Self.alex]?.id)
        await store.send(conversation: "alex")
        #expect(await fake.sentDrafts.last?.serverDraftID == id)
        #expect(store.serverDrafts[Self.alex] == nil && store.draftList().allSatisfy { $0.conversationID != "alex" })
        await store.select("maria")
        try await settle()
        let left = await fake.serverDrafts
        #expect(await fake.draftWrites == ["create alex/timeline"] && left.allSatisfy { $0.id != id })
    }
    @Test func aNetworkErrorKeepsTheTextAndRetriesOnTheNextTrigger() async throws {
        let (store, fake) = await started()
        await fake.simulateDraftFailure()
        store.setDraft("keep me", conversation: "alex", thread: nil)
        try await until { await fake.draftWrites == ["create alex/timeline"] }
        try await settle()
        #expect(store.drafts[Self.alex] == "keep me" && store.serverDrafts[Self.alex] == nil && store.error == nil)
        await fake.simulateDraftFailure(false)
        await store.select("maria")
        try await until { store.serverDrafts[Self.alex]?.text == "keep me" }
        #expect(await fake.draftWrites == ["create alex/timeline", "create alex/timeline"])
    }
    @Test func anEditIsNoDraft() async throws {
        let (store, fake) = await started()
        let mine = try #require(store.messages.first { $0.sender.id == store.me.id && $0.threadID == nil })
        store.edit(mine)
        try await settle()
        #expect(await fake.draftWrites.isEmpty && !store.draftList().contains { $0.text == mine.text })
    }

    // Merging on connect.
    @Test func aDraftOnlyGoogleHasFillsTheComposer() async throws {
        let (store, fake) = await started(server: [ServerDraft(id: "s1", conversationID: "alex", text: "from the phone")])
        #expect(store.drafts[Self.alex] == "from the phone")
        try await settle()
        #expect(await fake.draftWrites.isEmpty)
    }
    @Test func aDraftOnlyThisMacHasIsPushed() async throws {
        let cache = try Self.cache(LaunchSnapshot(accountID: "me", drafts: [Self.alex: "typed offline"], draftEdits: [Self.alex: .now]))
        let (store, fake) = await started(cache: cache)
        try await until { await fake.draftWrites == ["create alex/timeline"] }
        #expect(store.drafts[Self.alex] == "typed offline")
    }
    @Test func theNewerDraftWins() async throws {
        let hourAgo = Date.now.addingTimeInterval(-3_600)
        let cache = try Self.cache(LaunchSnapshot(accountID: "me", drafts: [Self.alex: "newer here", Self.maria: "older here"],
                                                  draftEdits: [Self.alex: .now, Self.maria: hourAgo]))
        let (store, fake) = await started(server: [ServerDraft(id: "a", conversationID: "alex", text: "older there", updatedAt: hourAgo),
                                                   ServerDraft(id: "m", conversationID: "maria", text: "newer there", updatedAt: .now)], cache: cache)
        #expect(store.drafts[Self.maria] == "newer there")
        try await until { await fake.draftWrites == ["update alex/timeline"] }
        #expect(store.drafts[Self.alex] == "newer here" && store.serverDrafts[Self.alex]?.text == "newer here")
    }
    @Test func aSavedDraftGoogleNoLongerHasWasSentElsewhere() async throws {
        let saved = ServerDraft(id: "s1", conversationID: "alex", text: "sent from the phone")
        let cache = try Self.cache(LaunchSnapshot(accountID: "me", drafts: [Self.alex: saved.text], serverDrafts: [Self.alex: saved]))
        let (store, fake) = await started(cache: cache)
        #expect(store.drafts[Self.alex] == nil)
        try await settle()
        #expect(await fake.draftWrites.isEmpty)
    }
    @Test func cachesFromBeforeServerDraftsCountTheirDraftsAsUnsaved() throws {
        let snapshot = try JSONDecoder().decode(LaunchSnapshot.self, from: Data(#"{"drafts":{"a/timeline":"hi","b/timeline":""}}"#.utf8))
        #expect(snapshot.draftEdits == ["a/timeline": .distantPast] && snapshot.serverDrafts.isEmpty)
    }

    /// A draft a send used up never comes back: not as a late echo of an earlier save, nor from a save that was on its way
    /// when the message went (which would make Google keep the old text as a new draft).
    @Test func anEchoOfASentDraftDoesNotRefillTheComposer() async throws {
        let (store, fake) = await started()
        store.setDraft("hello", conversation: "alex", thread: nil)
        try await until { store.serverDrafts[Self.alex] != nil }
        let saved = try #require(store.serverDrafts[Self.alex])
        await store.send(conversation: "alex")
        store.apply(.draftChanged(saved))   // Google's echo of that save, arriving after the send
        #expect(store.drafts[Self.alex, default: ""].isEmpty)
        await store.select("maria"); await store.select("alex")
        try await settle()
        #expect(store.drafts[Self.alex, default: ""].isEmpty)
        #expect(await fake.serverDrafts.allSatisfy { $0.conversationID != "alex" })
    }
    @Test func aSaveOnItsWayWhenTheMessageGoesIsUndone() async throws {
        let (store, fake) = await started()
        await fake.simulateSlowDraftWrites(.milliseconds(300))
        store.setDraft("hello wor", conversation: "alex", thread: nil)
        try await until { await fake.draftWrites == ["create alex/timeline"] }   // saving, not saved yet
        store.setDraft("hello world", conversation: "alex", thread: nil)
        await store.send(conversation: "alex")
        try await until { await fake.draftWrites.last == "delete alex/timeline" }
        #expect(await fake.serverDrafts.allSatisfy { $0.conversationID != "alex" })
        #expect(store.serverDrafts[Self.alex] == nil && store.drafts[Self.alex, default: ""].isEmpty)
        await store.select("maria"); await store.select("alex")
        try await settle()
        #expect(store.drafts[Self.alex, default: ""].isEmpty)
    }

    // Pushed changes.
    @Test func aPushedDraftFillsAComposerNobodyIsTypingIn() async throws {
        let (store, _) = await started()
        store.apply(.draftChanged(ServerDraft(id: "p1", conversationID: "alex", text: "from web")))
        #expect(store.drafts[Self.alex] == "from web")
        store.apply(.draftChanged(ServerDraft(id: "p1", conversationID: "alex", text: "stale echo", updatedAt: .now.addingTimeInterval(-60))))
        #expect(store.drafts[Self.alex] == "from web")
        store.apply(.draftDeleted("p1"))
        #expect(store.drafts[Self.alex] == nil && store.serverDrafts[Self.alex] == nil)
    }
    @Test func typingWinsOverAPushAtTheNextSave() async throws {
        let (store, fake) = await started()
        store.setDraft("mine", conversation: "alex", thread: nil)
        store.apply(.draftChanged(ServerDraft(id: "p1", conversationID: "alex", text: "theirs")))
        #expect(store.drafts[Self.alex] == "mine")
        await store.select("maria")
        try await until { await fake.draftWrites == ["update alex/timeline"] }
        #expect(store.serverDrafts[Self.alex]?.id == "p1" && store.serverDrafts[Self.alex]?.text == "mine")
    }

    // The Drafts shortcut.
    @Test func theDraftsShortcutListsEveryDraftAndOpensOne() async throws {
        let (store, _) = await started(server: [ServerDraft(id: "s1", conversationID: "launch", text: "Notes", updatedAt: .now.addingTimeInterval(-60))])
        store.setDraft("on it", conversation: "design", thread: "d4")
        await store.openShortcut(.drafts)
        #expect(store.shortcut == .drafts && store.shortcutMessages(.drafts).isEmpty)
        let list = store.draftList()
        #expect(list.map(\.text) == ["on it", "Notes"] && list[0].threadID == "d4" && list[1].threadID == nil)
        await store.open(conversation: list[0].conversationID, thread: list[0].threadID)
        #expect(store.shortcut == nil && store.selectedID == "design" && store.threadID == "d4")
        #expect(store.drafts[store.key("design", "d4")] == "on it")
    }
    @Test func theDemoHasADraft() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        #expect(store.draftList().map(\.conversationID) == ["launch"])
    }
}
