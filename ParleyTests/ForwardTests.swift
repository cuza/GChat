import Foundation
import Testing
@testable import Parley

struct ForwardMapperTests {
    static func forwarded(from group: Dynamite_GroupId, name: String) -> Dynamite_Message {
        .with {
            $0.id.parentID.topicID.topicID = "t1"; $0.id.messageID = "t1"; $0.creator.userID.id = "u1"; $0.textBody = "fwd test"
            $0.quotedMessageMetadata = .with {
                $0.messageID.parentID.topicID.topicID = "t0"; $0.messageID.messageID = "t0"; $0.textBody = "the original"
                $0.creator.name = "Maria"; $0.quoteType = .forward
                $0.group.groupID = group; $0.group.name = name
            }
        }
    }
    @Test func aForwardNamesItsSourceAndKeepsTheSourcesMessageID() throws {
        let proto = Self.forwarded(from: .with { $0.spaceID.spaceID = "s1" }, name: "Test Group")
        let message = try #require(DynamiteMapper.message(proto, in: "dm/a", selfID: "me", people: [:]))
        #expect(message.text == "fwd test")
        #expect(message.quote?.forwardedFrom == "Test Group")
        #expect(message.quote?.text == "the original" && message.quote?.sender == "Maria")
        #expect(message.quote?.id == DynamiteID.message("space/s1", topic: "t0", message: "t0"))
    }
    @Test func aForwardFromADirectMessageSaysSo() throws {
        let proto = Self.forwarded(from: .with { $0.dmID.dmID = "d1" }, name: "")
        let message = try #require(DynamiteMapper.message(proto, in: "dm/a", selfID: "me", people: [:]))
        #expect(message.quote?.forwardedFrom == "a direct message")
        #expect(message.quote?.id?.hasPrefix("dm/d1/") == true)
    }
    @Test func aQuoteReplyIsNotAForward() throws {
        var proto = Self.forwarded(from: .with { $0.spaceID.spaceID = "s1" }, name: "Test Group")
        proto.quotedMessageMetadata.quoteType = .quoteReply
        let message = try #require(DynamiteMapper.message(proto, in: "dm/a", selfID: "me", people: [:]))
        #expect(message.quote?.forwardedFrom == nil)
        #expect(message.quote?.id?.hasPrefix("dm/a/") == true)
    }
    @Test func forwardIsTwoOnTheWire() throws {
        let forward = QuotedMessage(sender: "Maria", text: "hi", id: "space/s1/t1/m1", lastUpdateMicros: 300, forwardedFrom: "Test Group")
        let ref = try #require(try DynamiteMapper.quotedRef(forward))
        let bytes: [UInt8] = try ref.serializedBytes()
        #expect(bytes.suffix(2) == [0x20, 0x02])   // field 4, varint 2: FORWARD
        #expect(ref.messageID.parentID.topicID.groupID.spaceID.spaceID == "s1" && ref.lastUpdateTime == 300)
    }
}

extension AuthTests {
    /// Checked live: Google leaves out a forward's quoted_message_metadata for the mobile client types.
    @Test func timelinesAreAskedForAsTheWebClient() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_ListTopicsResponse())])
        _ = try await backend.messages(in: "dm/a", thread: nil, before: nil)
        let request = try Dynamite_ListTopicsRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(request.requestHeader.clientType == .web)
    }
    @Test func aForwardIsANewTopicInTheDestinationNamingTheSource() async throws {
        let topic = try Self.proto(Dynamite_CreateTopicResponse.with { $0.topic.replies = [Self.message("m9", topic: "m9", at: 5, by: "me")] })
        let (backend, exchange) = try await Self.connected([topic])
        let forward = QuotedMessage(sender: "Maria", text: "hi", id: "space/s1/t1/t1", lastUpdateMicros: 77, forwardedFrom: "Test Group")
        _ = try await backend.send(MessageDraft(text: "", localID: "local-1", quoting: forward), to: "dm/a", thread: nil)
        let request = try Dynamite_CreateTopicRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(request.groupID.dmID.dmID == "a")
        #expect(request.messageInfo.quotedMessage.quoteType == .forward)
        #expect(request.messageInfo.quotedMessage.messageID.parentID.topicID.groupID.spaceID.spaceID == "s1")
        #expect(request.messageInfo.quotedMessage.lastUpdateTime == 77)
    }
}

@MainActor struct ForwardStoreTests {
    @Test func aForwardWaitsInTheDestinationsComposerAndSendsWithoutANote() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        let original = try #require(store.messages.first { $0.id == "d1" })
        store.forward(original, to: "alex")
        let scope = store.key("alex", nil)
        #expect(store.quoting[scope]?.forwardedFrom == "Design studio")
        #expect(store.quoting[scope]?.id == "d1")
        await store.send(conversation: "alex")
        let sent = await fake.sentDrafts.last
        #expect(sent?.text == "" && sent?.quoting?.forwardedFrom == "Design studio" && sent?.quoting?.id == "d1")
        #expect(store.quoting[scope] == nil)
    }
    @Test func anEmptyDraftWithoutAForwardSendsNothing() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        await store.send(conversation: "alex")
        #expect(await fake.sentDrafts.isEmpty)
    }
}
