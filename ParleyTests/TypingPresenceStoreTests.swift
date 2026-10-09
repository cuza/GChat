import Foundation
import Testing
@testable import Parley

/// The store's rules for typing, presence and receipts, on an injected clock.
@MainActor struct TypingPresenceStoreTests {
    private final class Clock { var now = Date(timeIntervalSince1970: 1_000_000) }
    private func store(_ fake: FakeBackend = FakeBackend()) async -> (ChatStore, Clock) {
        let clock = Clock()
        let store = ChatStore(backend: fake)
        store.now = { clock.now }
        store.isAppActive = { false }   // keeps the sweep's presence refresh out of these tests
        await store.start()
        return (store, clock)
    }
    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_000_000 + seconds) }

    @Test func typingExpiresEightSecondsAfterItArrives() async {
        let (store, clock) = await store()
        store.apply(.typingChanged("maria", nil, "maria", isTyping: true))
        clock.now = at(7); store.sweepTyping()
        #expect(store.typists("maria") == ["maria"])
        store.apply(.typingChanged("maria", nil, "maria", isTyping: true))   // a repeat refreshes it
        clock.now = at(14); store.sweepTyping()
        #expect(store.typists("maria") == ["maria"])
        clock.now = at(15.5); store.sweepTyping()
        #expect(store.typists("maria").isEmpty)
    }
    @Test func typingIsPerThreadAndEndsOnStopMessageOrDisconnect() async {
        let (store, _) = await store()
        store.apply(.typingChanged("design", "d4", "maria", isTyping: true))
        store.apply(.typingChanged("design", nil, "alex", isTyping: true))
        #expect(store.typists("design", thread: "d4") == ["maria"] && store.typists("design") == ["alex"])
        store.apply(.typingChanged("design", nil, "alex", isTyping: false))
        #expect(store.typists("design").isEmpty)
        store.apply(.messageUpserted(Message(id: "new", conversationID: "design", threadID: "d4", sender: Person(id: "maria", name: "Maria Chen"),
                                             text: "done", createdAt: store.now())))
        #expect(store.typists("design", thread: "d4").isEmpty)
        store.apply(.typingChanged("design", nil, "alex", isTyping: true))
        store.apply(.connectionChanged(.reconnecting))
        #expect(store.typists("design").isEmpty)
    }
    @Test func typingLineNamesFirstNames() {
        #expect(ChatStore.typingLine([]) == nil)
        #expect(ChatStore.typingLine(["Maria Chen"]) == "Maria is typing…")
        #expect(ChatStore.typingLine(["Maria Chen", "Alex Rivera"]) == "Maria and Alex are typing…")
        #expect(ChatStore.typingLine(["A", "B", "C", "D"]) == "Several people are typing…")
    }
    @Test func typingIsSentAtMostEveryFiveSecondsAndNeverWhileEditing() async throws {
        let fake = FakeBackend()
        let (store, clock) = await store(fake)
        await store.typed("h", conversation: "maria", thread: nil)
        clock.now = at(4); await store.typed("hi", conversation: "maria", thread: nil)
        await store.typed("hi", conversation: "maria", thread: "m1")      // another composer
        await store.typed("  ", conversation: "alex", thread: nil)        // nothing written
        clock.now = at(5); await store.typed("hi!", conversation: "maria", thread: nil)
        let own = Message(id: "m2", conversationID: "maria", sender: store.me, text: "x")
        store.messages.append(own); store.edit(own)
        clock.now = at(20); await store.typed("y", conversation: "maria", thread: nil)
        #expect(await fake.typingSent == ["maria/timeline", "maria/m1", "maria/timeline"])
    }
    @Test func theOpenConversationIsWatchedOnceEachTimeItChanges() async {
        let fake = FakeBackend()
        let (store, _) = await store(fake)
        let first = store.selectedID!
        await store.select(first)
        await store.select("alex")
        #expect(await fake.watched == [[first], ["alex"]])
    }
    @Test func receiptsMergePerReaderAndDisablingClearsThem() async {
        let (store, _) = await store()
        store.apply(.readReceiptsChanged("launch", ["maria": at(10)], enabled: true))
        store.apply(.readReceiptsChanged("launch", ["alex": at(20), "maria": at(5)], enabled: nil))
        #expect(store.readReceipts["launch"] == ["maria": at(10), "alex": at(20)])
        store.apply(.readReceiptsChanged("launch", [:], enabled: false))
        store.apply(.readReceiptsChanged("launch", ["alex": at(30)], enabled: nil))   // still off
        #expect(store.readReceipts["launch"] == nil)
        store.apply(.readReceiptsChanged("launch", ["alex": at(30)], enabled: true))
        #expect(store.readReceipts["launch"] == ["alex": at(30)])
    }
    @Test func seenSitsUnderMyNewestMessageEachReaderCovers() async throws {
        let (store, _) = await store()
        let maria = Person(id: "maria", name: "Maria Chen"), alex = Person(id: "alex", name: "Alex Rivera")
        store.messages = [10, 20, 30].map { Message(id: "own\(Int($0))", conversationID: "launch", sender: store.me, text: "x", createdAt: at($0)) }
            + [Message(id: "theirs", conversationID: "launch", sender: alex, text: "y", createdAt: at(25))]
        store.apply(.readReceiptsChanged("launch", ["maria": at(25), "alex": at(40)], enabled: true))
        let launch = try #require(store.conversations.first { $0.id == "launch" })
        #expect(store.seen(in: launch) == ["own20": ["maria"], "own30": ["alex"]])
        #expect(store.readers(of: store.messages[0]) == ["alex", "maria"])
        #expect(store.name(of: "maria", in: "launch") == maria.name)
        store.apply(.readReceiptsChanged("design", ["maria": at(99)], enabled: true))
        #expect(store.seen(in: try #require(store.conversations.first { $0.id == "design" })).isEmpty)   // named spaces show none
    }
    @Test func presenceIsCachedForSixtySecondsAndTypingMarksActive() async throws {
        let fake = FakeBackend()
        let (store, clock) = await store(fake)
        await store.refreshPresence()
        let asked = try #require(await fake.presenceRequests.first)
        #expect(Set(asked).isSuperset(of: ["maria", "alex"]) && !asked.contains("me"))
        try await until { store.presence["maria"] != nil && store.presence["alex"] != nil }
        #expect(store.presence["maria"] == .available && store.presence["alex"] == .away)
        clock.now = at(30); await store.refreshPresence()
        #expect(await fake.presenceRequests.count == 1)
        store.apply(.typingChanged("alex", nil, "alex", isTyping: true))
        #expect(store.presence["alex"] == .available)
        clock.now = at(61); await store.refreshPresence()
        #expect(await fake.presenceRequests.last.map(Set.init) == Set(asked).subtracting(["alex"]))   // alex was seen at 30
        store.apply(.presenceChanged("maria", .doNotDisturb, status: "🌴 Away"))
        #expect(store.presence["maria"] == .doNotDisturb && store.statuses["maria"] == "🌴 Away")
        store.apply(.presenceChanged("maria", nil, status: nil))   // DND over: unknown until asked again
        #expect(store.presence["maria"] == nil && store.statuses["maria"] == nil)
    }
    /// Lets the event task apply what the fake already emitted.
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
    }
}
