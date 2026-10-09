import Foundation
import Testing
@testable import Parley

@MainActor struct FormattedDraftTests {
    @Test func sendingTrimsAndShiftsFormatting() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        let id = try #require(store.selectedID)
        store.setDraft("  hi there\n", formatting: [TextStyleRange(style: .bold, start: 2, length: 2), TextStyleRange(style: .italic, start: 5, length: 6)],
                       conversation: id, thread: nil)
        await fake.simulateSendFailure()   // keeps the local echo in the store
        await store.send(conversation: id)
        let expected = [TextStyleRange(style: .bold, start: 0, length: 2), TextStyleRange(style: .italic, start: 3, length: 5)]
        #expect(store.messages.first { $0.delivery == .failed }?.formatting == expected)
        #expect(await fake.sentDrafts.last?.formatting == expected)
        #expect(store.draftFormatting[store.key(id, nil)] ?? [] == [])
    }
    @Test func editingLoadsTheMessageFormatting() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let id = try #require(store.selectedID)
        store.setDraft("hey", formatting: [TextStyleRange(style: .bold, start: 0, length: 3)], conversation: id, thread: nil)
        await store.send(conversation: id)
        let own = try #require(store.messages.last { $0.sender.id == store.me.id })
        store.edit(own)
        #expect(store.draftFormatting[store.key(id, nil)] == own.formatting)
    }
    @Test func oldLaunchCachesDecodeWithoutDraftFormatting() throws {
        let snapshot = try JSONDecoder().decode(LaunchSnapshot.self, from: Data(#"{"conversations":[],"messages":[],"drafts":{"a/timeline":"hi"}}"#.utf8))
        #expect(snapshot.drafts == ["a/timeline": "hi"] && snapshot.draftFormatting.isEmpty)
    }
    @Test func listsBecomeItemsInsideOneListAnnotation() {
        let annotations = DynamiteMapper.annotations([TextStyleRange(style: .listItem, start: 0, length: 4), TextStyleRange(style: .listItem, start: 4, length: 3),
                                                      TextStyleRange(style: .bold, start: 0, length: 1), TextStyleRange(style: .link(URL(string: "https://a.b")!), start: 1, length: 1)])
        let shapes = annotations.map { "\($0.formatMetadata.formatType) \($0.startIndex)+\($0.length)" }
        #expect(shapes == ["bulletedListItem 0+4", "bulletedListItem 4+3", "bold 0+1", "typeUnspecified 1+1", "bulletedList 0+7"])
        #expect(annotations.filter { $0.type != .formatData }.map(\.type) == [.url])   // a link is a URL annotation
    }
}

/// Network-stubbed: joins the serialized AuthTests suite (the stub registry is global).
extension AuthTests {
    @Test func formattedSendsCarryFormatAnnotationsInUTF16() async throws {
        let topic = try Self.proto(Dynamite_CreateTopicResponse.with { $0.topic.replies = [Self.message("m9", topic: "m9", at: 5, by: "me")] })
        let reply = try Self.proto(Dynamite_CreateMessageResponse.with { $0.message = Self.message("r9", topic: "m9", at: 6, by: "me") })
        let (backend, exchange) = try await Self.connected([topic, reply, topic])
        let bold = [TextStyleRange(style: .bold, start: 3, length: 2)]   // "😀 " is three UTF-16 units
        let sent = try await backend.send(MessageDraft(text: "😀 hi", localID: "local-1", formatting: bold), to: "dm/a", thread: nil)
        _ = try await backend.send(MessageDraft(text: "😀 hi", localID: "local-2", formatting: bold), to: "dm/a", thread: sent.id)
        _ = try await backend.send(MessageDraft(text: "plain", localID: "local-3"), to: "dm/a", thread: nil)
        let topics = try exchange.requests.filter { $0.url?.path == "/api/create_topic" }.map { try Dynamite_CreateTopicRequest(serializedBytes: Self.body($0)) }
        let replies = try exchange.requests.filter { $0.url?.path == "/api/create_message" }.map { try Dynamite_CreateMessageRequest(serializedBytes: Self.body($0)) }
        for (annotations, accepts) in [(topics[0].annotations, topics[0].messageInfo.acceptFormatAnnotations),
                                       (replies[0].annotations, replies[0].messageInfo.acceptFormatAnnotations)] {
            #expect(accepts)
            #expect(annotations.count == 1)
            #expect(annotations.first?.type == .formatData && annotations.first?.formatMetadata.formatType == .bold)
            #expect(annotations.first?.startIndex == 3 && annotations.first?.length == 2)
        }
        #expect(topics[1].annotations.isEmpty && topics[1].hasMessageInfo && !topics[1].messageInfo.acceptFormatAnnotations)
    }
    @Test func formattedEditsCarryFormatAnnotations() async throws {
        var edited = Self.message("h1", topic: "t1", at: 1, by: "me"); edited.textBody = "new"
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_EditMessageResponse.with { $0.message = edited })])
        try await backend.edit("space/x/t1/h1", text: "new", formatting: [TextStyleRange(style: .strike, start: 0, length: 3)])
        let request = try Dynamite_EditMessageRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(request.messageInfo.acceptFormatAnnotations)
        #expect(request.annotations.map(\.formatMetadata.formatType) == [.strike] && request.annotations.first?.length == 3)
    }
}
