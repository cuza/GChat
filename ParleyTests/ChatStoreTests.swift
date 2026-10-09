import Foundation
import Testing
@testable import Parley

@MainActor
struct ChatStoreTests {
    @Test func startAdoptsBackendIdentity() async {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        #expect(store.me == FakeBackend.me)
        #expect(!store.conversations.isEmpty)
    }
    @Test func retryResendsTheSameLocalID() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        let id = try #require(store.selectedID)
        await fake.simulateSendFailure()
        store.setDraft("hi", conversation: id, thread: nil)
        await store.send(conversation: id)
        let failed = try #require(store.messages.first { $0.delivery == .failed })
        await store.retry(failed)
        let ids = await fake.sentDrafts.map(\.localID)
        #expect(ids.count == 2 && ids[0] == ids[1])
    }
    @Test func reselectingRefetchesHistory() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let id = try #require(store.selectedID)
        store.messages.removeAll()   // the server has messages the store doesn't
        await store.select(id)
        #expect(!store.timeline(id).isEmpty)
    }
    @Test func signedOutStartCanBeRetried() async {
        let fake = FakeBackend()
        await fake.simulateSignedOut()
        let store = ChatStore(backend: fake)
        await store.start()
        #expect(store.connection == .signedOut)
        #expect(store.conversations.isEmpty)
        await store.start()   // author signed in, then pressed Try again
        #expect(store.me == FakeBackend.me)
        #expect(!store.conversations.isEmpty)
    }
    @Test func aCancelledStartIsNotAnErrorAndKeepsTheConnection() async {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        let connection = store.connection
        await fake.simulateCancelledConnect()
        await store.start()
        #expect(store.error == nil)
        #expect(store.connection == connection)
    }
    @Test(arguments: [AuthFailure.signInRequired, .bootstrapRedirect(AuthFailure.signInCategory), .bootstrapRejected(401)])
    func aSessionLostMidUseShowsTheExpiredBannerNotAnError(_ failure: AuthFailure) async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        let id = try #require(store.selectedID)
        await fake.simulateSessionExpiredOnNextSend(failure)
        store.setDraft("hi", conversation: id, thread: nil)
        await store.send(conversation: id)
        #expect(store.error == nil)
        #expect(store.sessionExpired)
    }
    @Test func showInChatHighlightsASharedItemsMessageOrOpensItsThread() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let id = try #require(store.selectedID)
        let message = try #require(store.timeline(id).last)
        await store.showShared(SharedContent.Item(attachment: Attachment(name: "a", kind: .file), date: .now, sender: "", messageID: message.id), in: id)
        #expect(store.highlightedID == message.id)
        let reply = "\(id)/t1/m2"   // a reply: its message differs from its topic
        await store.showShared(SharedContent.Item(attachment: Attachment(name: "b", kind: .file), date: .now, sender: "", messageID: reply), in: id)
        #expect(store.threadID == "\(id)/t1/t1" && store.highlightedID == reply)
    }
    @Test func aChatLinkOpensItsConversationOrIsLeftToTheBrowser() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let other = try #require(store.conversations.last { $0.id != store.selectedID })
        #expect(await store.open(ChatLink(conversations: ["dm/unknown", other.id])))
        #expect(store.selectedID == other.id)
        #expect(await !store.open(ChatLink(conversations: ["space/not-in-the-sidebar"])))
        #expect(store.selectedID == other.id)
    }
    @Test func pushedMessagesCountAsUnreadOnlyElsewhereAndOnce() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let selected = try #require(store.selectedID)
        let other = try #require(store.conversations.first { $0.id != selected })
        let selectedUnread = store.conversations.first { $0.id == selected }?.unread
        let maria = Person(id: "maria", name: "Maria Chen")
        let incoming = Message(id: "push-1", conversationID: other.id, sender: maria, text: "hi")
        store.apply(.messageUpserted(incoming))
        store.apply(.messageUpserted(incoming))                                                            // echo/duplicate
        store.apply(.messageUpserted(Message(id: "push-2", conversationID: other.id, sender: store.me, text: "mine")))
        store.apply(.messageUpserted(Message(id: "push-3", conversationID: other.id, threadID: "x", sender: maria, text: "reply")))
        store.apply(.messageUpserted(Message(id: "push-4", conversationID: selected, sender: maria, text: "here")))
        #expect(store.conversations.first { $0.id == other.id }?.unread == other.unread + 1)
        #expect(store.conversations.first { $0.id == selected }?.unread == selectedUnread)
    }
    @Test func resyncReloadsConversations() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        store.conversations.removeAll()
        store.apply(.resync)
        for _ in 0..<100 where store.conversations.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!store.conversations.isEmpty)
    }

    @Test func resyncKeepsOpenThreadAndEdit() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let head = try #require(store.messages.first { $0.replyCount > 0 })
        await store.select(head.conversationID)
        await store.openThread(head)
        let own = try #require(store.timeline(head.conversationID).last { $0.sender.id == store.me.id })
        store.edit(own)
        store.conversations.removeAll()
        store.apply(.resync)
        for _ in 0..<100 where store.conversations.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.threadID == head.id)
        #expect(store.editingID(own.conversationID, thread: own.threadID) == own.id)
    }

    /// A message jumped to is outlined for a moment, as Telegram flashes it, then goes back to normal by itself.
    @Test func aHighlightFadesByItself() async throws {
        let store = ChatStore(backend: FakeBackend())
        store.highlightDuration = .milliseconds(100)
        store.highlightedID = "a"
        try await Task.sleep(for: .milliseconds(60))
        store.highlightedID = "b"                       // a newer jump restarts the wait
        try await Task.sleep(for: .milliseconds(60))
        #expect(store.highlightedID == "b")
        try await Task.sleep(for: .milliseconds(150))
        #expect(store.highlightedID == nil)
    }

    /// The timeline is sorted once per change, not on every read, and every change shows: added, edited, removed.
    @Test func aTimelineFollowsEveryChangeToItsMessages() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let room = try #require(store.conversations.first).id
        await store.load(room)
        let before = store.timeline(room)
        #expect(store.timeline(room) == before)   // a second read gives the same, in order
        let newest = Message(id: "\(room)/new", conversationID: room, sender: store.me, text: "hi", createdAt: .now.addingTimeInterval(60))
        store.messages.append(newest)
        #expect(store.timeline(room).last == newest)
        let i = try #require(store.messages.firstIndex { $0.id == newest.id })
        store.messages[i].text = "edited"
        #expect(store.timeline(room).last?.text == "edited")
        store.messages.removeAll { $0.id == newest.id }
        #expect(store.timeline(room) == before)
    }

    /// Marking read happens in the background and is tried again on the next visit: a refusal is logged, not shown.
    @Test func aRefusedReadMarkShowsNoError() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        await fake.simulateReadFailure()
        await store.markRead(try #require(store.conversations.first).id)
        #expect(store.error == nil)
    }

    /// Each composer has its own edit: a thread window's edit is not the main composer's, and leaving a conversation
    /// ends only the edits in the main window, clearing their text so it isn't left behind as a draft.
    @Test func anEditBelongsToItsComposer() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let head = try #require(store.messages.first { $0.replyCount > 0 })
        let room = head.conversationID
        await store.select(room)
        var reply = Message(id: "\(room)/mine-reply", conversationID: room, sender: store.me, text: "in the thread"); reply.threadID = head.id
        let main = Message(id: "\(room)/mine-main", conversationID: room, sender: store.me, text: "in the room")
        store.messages += [reply, main]
        store.edit(reply)   // in the thread's own window
        #expect(store.editingID(room, thread: head.id) == reply.id && store.editingID(room, thread: nil) == nil)
        store.setDraft("a new message", conversation: room, thread: nil)
        await store.send(conversation: room)   // Return in the main composer sends, it doesn't edit the reply
        #expect(store.timeline(room).contains { $0.text == "a new message" })
        #expect(store.messages.first { $0.id == reply.id }?.text == "in the thread" && store.editingID(room, thread: head.id) == reply.id)
        store.edit(main)
        let other = try #require(store.conversations.first { $0.id != room }).id
        await store.select(other)
        #expect(store.editingID(room, thread: nil) == nil && store.drafts[store.key(room, nil), default: ""].isEmpty)
        #expect(store.editingID(room, thread: head.id) == reply.id && store.drafts[store.key(room, head.id)] == "in the thread")
    }

    /// Popping the thread out closes the pane and names the thread for its own window, whose timeline keeps its replies.
    @Test func detachingTheOpenThreadClosesThePaneAndKeepsItsReplies() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let head = try #require(store.messages.first { $0.replyCount > 0 })
        await store.select(head.conversationID)
        await store.openThread(head)
        let replies = store.timeline(head.conversationID, thread: head.id).count
        #expect(store.detachThread(in: head.conversationID) == ThreadRef(conversation: head.conversationID, thread: head.id))
        #expect(store.threadID == nil)
        #expect(store.timeline(head.conversationID, thread: head.id).count == replies && replies > 0)
        #expect(store.detachThread(in: head.conversationID) == nil)   // nothing open
    }
    /// macOS restores a thread or conversation window by its ids, even one the signed-in account doesn't have
    /// (another account's, or one it left): it should close, not ask the server for it.
    @Test func aRestoredWindowKnowsWhetherItsConversationIsThisAccounts() async throws {
        let store = ChatStore(backend: FakeBackend())
        #expect(store.hasConversation("dm/elsewhere") == nil)   // the list hasn't come: wait
        await store.start()
        let room = try #require(store.conversations.first).id
        #expect(store.hasConversation(room) == true)
        #expect(store.hasConversation("dm/elsewhere") == false)
    }

    /// Back and forward walk the places opened, conversations and shortcuts alike, as a browser does.
    @Test func backAndForwardWalkThePlacesOpened() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let ids = store.conversations.prefix(2).map(\.id)
        try #require(ids.count == 2)
        await store.select(ids[0])
        await store.openShortcut(.starred)
        await store.select(ids[1])
        await store.goBack()
        #expect(store.shortcut == .starred)
        await store.goBack()
        #expect(store.shortcut == nil && store.selectedID == ids[0])
        #expect(store.canGoForward)
        await store.goForward()
        #expect(store.shortcut == .starred)
        await store.select(ids[1])   // a new place drops the forward history
        #expect(!store.canGoForward && store.canGoBack)
        await store.select(ids[1])   // reopening the current place adds nothing
        await store.goBack()
        #expect(store.shortcut == .starred)
    }

    @Test func jumpingToAnUnknownConversationAddsIt() async {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        await store.jump(Message(id: "dm/zz/t1/t1", conversationID: "dm/zz", sender: Person(id: "u", name: "U"), text: "hit"))
        #expect(store.selected?.id == "dm/zz")
    }
    @Test func pushIntoTheOpenConversationMarksItReadWhileActive() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        store.isAppActive = { true }
        await store.start()
        let selected = try #require(store.selectedID)
        let before = await fake.markedRead.count
        store.apply(.messageUpserted(Message(id: "push-9", conversationID: selected, sender: Person(id: "maria", name: "Maria"), text: "hi")))
        for _ in 0..<100 where await fake.markedRead.count == before { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await fake.markedRead.count == before + 1)
    }

    /// Seen live: a new group DM showed an unread badge while open, after my own first message, from the pushed sidebar entry.
    @Test func aPushedUpdateToTheOpenConversationKeepsItRead() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        store.isAppActive = { true }
        await store.start()
        var room = try #require(store.selected)
        room.unread = 1
        let before = await fake.markedRead.count
        store.apply(.conversationUpserted(room))
        #expect(store.selected?.unread == 0)
        for _ in 0..<100 where await fake.markedRead.count == before { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await fake.markedRead.count == before + 1)
    }

    /// Seen live: a link to the top of a long conversation showed one page's spinner and stopped. The timeline's own
    /// older-page load was in flight, and each page the search asked for returned at once without loading.
    @Test func goingToAnOldMessageWaitsForAnOlderPageAlreadyLoading() async throws {
        let store = ChatStore(backend: FakeBackend(longHistory: 300, latency: .milliseconds(30)))
        await store.start()
        await store.select("engineering")
        #expect(!store.messages.contains { $0.id == "e0" })
        async let timeline: Void = store.loadOlderIfNeeded("engineering")   // the timeline near its top, already loading
        async let search: Void = store.showQuoted("e0", in: "engineering", pages: 50)
        _ = await (timeline, search)
        let loaded = store.timeline("engineering")
        #expect(store.highlightedID == "e0", "oldest \(loaded.first?.id ?? "-"), \(loaded.count) loaded, more: \(store.hasMore.contains(store.key("engineering", nil)))")
    }
    @Test func nearingTheTopLoadsOneOlderPageAtATime() async throws {
        let fake = FakeBackend(latency: .milliseconds(100))
        let store = ChatStore(backend: fake)
        await store.start()
        let id = try #require(store.selectedID)
        let scope = store.key(id, nil)
        let before = await fake.historyRequests
        store.hasMore.insert(scope)
        async let first: Void = store.loadOlderIfNeeded(id)
        async let second: Void = store.loadOlderIfNeeded(id)   // while the first is in flight: dropped
        _ = await (first, second)
        #expect(await fake.historyRequests == before + 1)
        store.hasMore.insert(scope)   // the server says there is still more
        await store.loadOlderIfNeeded(id)   // the page landed: the next one goes at once, no cooldown
        #expect(await fake.historyRequests == before + 2)
        store.hasMore.remove(scope)
        await store.loadOlderIfNeeded(id)   // nothing more: no request
        #expect(await fake.historyRequests == before + 2)
    }
}

/// The launch cache belongs to one account: the next account on this Mac must not see or send the previous one's.
@MainActor
struct LaunchCacheAccountTests {
    private static func cache() -> LaunchCache { LaunchCache(url: URL.temporaryDirectory.appending(path: "parley-cache-\(UUID().uuidString).json")) }

    @Test func anotherAccountsCacheIsDiscardedWhenThisAccountConnects() async throws {
        let cache = Self.cache()
        try cache.save(LaunchSnapshot(accountID: "someone-else", drafts: ["engineering/timeline": "their unsent draft"]))
        let store = ChatStore(backend: FakeBackend(), cache: cache)
        #expect(!store.drafts.isEmpty)   // shown until the server says who this is
        await store.start()
        #expect(store.drafts["engineering/timeline"] == nil && store.me == FakeBackend.me)
        store.flush()
        #expect(cache.load().accountID == FakeBackend.me.id)
    }
    /// Home's thread rows come back with the cache, so a conversation shown as its thread doesn't flash up as a plain row first.
    @Test func homeThreadsComeBackWithTheCache() async throws {
        let cache = Self.cache()
        let first = ChatStore(backend: FakeBackend(), cache: cache)
        await first.start()
        #expect(!first.homeThreads.isEmpty)
        first.flush()
        let next = ChatStore(backend: FakeBackend(), cache: cache)
        #expect(next.homeThreads.map(\.id) == first.homeThreads.map(\.id))
    }
    @Test func ownCacheSurvivesConnect() async throws {
        let cache = Self.cache()
        try cache.save(LaunchSnapshot(accountID: FakeBackend.me.id, drafts: ["engineering/timeline": "my draft"]))
        let store = ChatStore(backend: FakeBackend(), cache: cache)
        await store.start()
        #expect(store.drafts["engineering/timeline"] == "my draft")
    }
    @Test func flushWritesTheCacheWithoutWaitingForTheDelay() async throws {
        let cache = Self.cache()
        let store = ChatStore(backend: FakeBackend(), cache: cache)
        await store.start()
        let id = try #require(store.selectedID)
        store.setDraft("typed just before quitting", conversation: id, thread: nil)
        store.flush()
        #expect(cache.load().drafts.values.contains("typed just before quitting"))
    }
    @Test func aChangedModelLosesHistoryButKeepsDrafts() throws {
        let cache = Self.cache()
        let json = #"{"accountID":"me","conversations":[{"unexpected":true}],"messages":[],"drafts":{"k":"kept"}}"#
        try Data(json.utf8).write(to: cache.url)
        let snapshot = cache.load()
        #expect(snapshot.conversations.isEmpty && snapshot.drafts["k"] == "kept")
    }
}

/// Reaching the top while the newest page is still reloading: the table asks once, and a reload of the same rows
/// gives it no reason to ask again, so the older page must follow the reload instead of being dropped.
@MainActor struct OlderPageDuringReloadTests {
    @Test func askingForOlderDuringAReloadStillPagesBack() async throws {
        let store = ChatStore(backend: FakeBackend(longHistory: 200, latency: .milliseconds(200)))
        await store.start()
        await store.select("engineering")
        let before = store.timeline("engineering").count
        let reload = Task { await store.select("engineering") }   // reopening: the newest page reloads
        while !store.loading.contains(store.key("engineering", nil)) { await Task.yield() }
        await store.loadOlderIfNeeded("engineering")              // the table reached the top meanwhile
        await reload.value
        #expect(store.timeline("engineering").count > before)
    }
}
