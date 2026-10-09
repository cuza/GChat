import Foundation
import Testing
@testable import Parley

/// The demo workspace's apps (README screenshots): a code-review app's link preview, a documents app's comment card
/// whose Reply works in the card, and a translated message.
@MainActor struct DemoAppsTests {
    @Test func theDocumentsAppsReplyUpdatesItsCard() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        #expect(store.conversations.first { $0.id == "notebook" }?.app == .bot)   // listed under Apps
        await store.select("notebook")
        let message = try #require(store.messages.first { $0.conversationID == "notebook" && $0.attachments.first?.card != nil })
        let card = try #require(message.attachments.first?.card)
        #expect(card.inputs == [Card.Input(name: "REPLY_TO_COMMENT", value: "")])
        let links = card.sections.flatMap { $0 }.compactMap { if case .links(let links) = $0 { links } else { nil } }.flatMap { $0 }
        let reply = try #require(links.first { $0.title == "Reply" }?.action)
        #expect(links.first { $0.title == "Open" }?.trailing == true && links.first { $0.title == "Resolve" }?.action != nil)
        await store.clickCard(message, action: reply, inputs: [Card.Input(name: "REPLY_TO_COMMENT", value: "Thursday works for me.")])
        let updated = try #require(store.messages.first { $0.id == message.id }?.attachments.first?.card)
        #expect(updated.sections.flatMap { $0 }.contains { if case .row(_, _, "Dave", "Thursday works for me.", _, _) = $0 { true } else { false } })
        #expect(store.error == nil)
    }
    @Test func theDesignSpaceShowsALinkPreviewAndATranslation() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        await store.select("design")
        let preview = try #require(store.messages.compactMap { $0.attachments.first?.card }.first { $0.by?.name == "Shipyard" })
        #expect(preview.sections.flatMap { $0 }.contains { if case .text(_, _, 2) = $0 { true } else { false } })
        let translated = try #require(store.messages.first { $0.translation != nil })
        #expect(translated.translation?.from == "es" && translated.sender.name == "Maria Chen")
    }
}
