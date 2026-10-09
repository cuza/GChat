import Foundation
import Testing
@testable import Parley

/// Sidebar actions in the store: shown at once, sent to the server, put back when the server refuses.
@MainActor
struct SidebarStoreTests {
    private func started(latency: Duration = .zero) async -> (ChatStore, FakeBackend) {
        let fake = FakeBackend(latency: latency)
        let store = ChatStore(backend: fake)
        await store.start()
        return (store, fake)
    }
    private func room(_ store: ChatStore, _ id: ConversationID) -> Conversation? { store.conversations.first { $0.id == id } }

    @Test func pinShowsBeforeTheServerAnswers() async throws {
        let (store, fake) = await started(latency: .milliseconds(400))
        let pending = Task { await store.setPinned(true, "alex") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(room(store, "alex")?.pinned == true)
        await pending.value
        #expect(await fake.changes == ["pin alex"])
    }
    @Test func pinAndMuteSurviveARefresh() async throws {
        let (store, fake) = await started()
        await store.setPinned(true, "alex")
        await store.setMuted(true, "alex")
        await store.setPinned(false, "maria")
        try await store.refresh()
        #expect(room(store, "alex")?.pinned == true && room(store, "alex")?.muted == true && room(store, "maria")?.pinned == false)
        #expect(await fake.changes == ["pin alex", "mute alex", "unpin maria"])
        #expect(store.error == nil)
    }
    @Test func aRefusedPinOrMuteRollsBackAndSaysWhy() async throws {
        let (store, fake) = await started()
        await fake.simulateChangeFailure()
        await store.setPinned(true, "alex")
        #expect(room(store, "alex")?.pinned == false && store.error != nil)
        store.error = nil
        await fake.simulateChangeFailure()
        await store.setMuted(false, "engineering")
        #expect(room(store, "engineering")?.muted == true && store.error != nil)
    }
    @Test func markUnreadShowsUnreadAndSurvivesARefresh() async throws {
        let (store, fake) = await started()
        #expect(room(store, "launch")?.unread == 0)
        await store.markUnread("launch")
        #expect(room(store, "launch")?.unread == 1)
        try await store.refresh()
        #expect(room(store, "launch")?.unread == 1)
        #expect(await fake.changes == ["unread launch"])
    }
    @Test func aRefusedMarkUnreadRollsBack() async throws {
        let (store, fake) = await started()
        await fake.simulateChangeFailure()
        await store.markUnread("launch")
        #expect(room(store, "launch")?.unread == 0 && store.error != nil)
    }
    @Test func leaveRemovesTheConversationAndARefusalPutsItBack() async throws {
        let (store, fake) = await started()
        let index = try #require(store.conversations.firstIndex { $0.id == "general" })
        await fake.simulateChangeFailure()
        await store.leave("general")
        #expect(store.conversations.firstIndex { $0.id == "general" } == index && store.error != nil)
        store.error = nil
        await store.leave("general")
        #expect(room(store, "general") == nil && store.error == nil)
        try await store.refresh()
        #expect(room(store, "general") == nil)
    }
    @Test func leavingTheOpenConversationMovesTheSelection() async throws {
        let (store, _) = await started()
        let selected = try #require(store.selectedID)
        await store.leave(selected)
        #expect(store.selectedID != selected && store.selectedID != nil)
    }
    /// Pin and mute come from the server, also when a conversation changes elsewhere.
    @Test func upsertedConversationsTakeTheServersPinAndMute() async throws {
        let (store, _) = await started()
        var known = try #require(store.conversations.first { $0.pinned })
        known.name = "Renamed"; known.pinned = false; known.muted = true
        store.apply(.conversationUpserted(known))
        let updated = try #require(room(store, known.id))
        #expect(updated.name == "Renamed" && !updated.pinned && updated.muted)
    }
}
