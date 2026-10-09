import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parley

/// Home: the conversations with activity, most recent first, each with its newest message.
@MainActor
struct HomeTests {
    private func started(landing: Shortcut? = nil) async -> (ChatStore, FakeBackend) {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        store.shortcut = landing
        await store.start()
        return (store, fake)
    }
    @Test func homeLeadsTheShortcuts() {
        #expect(Shortcut.allCases.first == .home && Shortcut.home.title == "Home")
    }
    @Test func aConversationsActivityIsTheServersSortTime() {
        let item = Dynamite_WorldItemLite.with { $0.groupID.spaceID.spaceID = "s"; $0.roomName = "S"; $0.sortTimestamp = 1_700_000_000_000_000 }
        #expect(DynamiteMapper.conversation(item, selfID: "me", people: [:])?.activity == Date(timeIntervalSince1970: 1_700_000_000))
        let none = Dynamite_WorldItemLite.with { $0.groupID.spaceID.spaceID = "s"; $0.roomName = "S" }
        #expect(DynamiteMapper.conversation(none, selfID: "me", people: [:])?.activity == nil)
    }
    @Test func launchingOnHomeOpensNoConversationAndReadsNothing() async throws {
        let (store, fake) = await started(landing: .home)
        #expect(store.shortcut == .home && !store.conversations.isEmpty)
        #expect(await fake.markedRead.isEmpty)
    }
    @Test func rowsAreMostRecentFirstAndANewMessageMovesItsConversationUp() async throws {
        let (store, fake) = await started()
        await store.openShortcut(.home)
        #expect(store.shortcut == .home)
        let rows = store.homeRows().filter { $0.thread == nil }
        #expect(rows.count == store.conversations.filter { $0.activity != nil }.count)
        let times = rows.map { max($0.room.activity ?? .distantPast, $0.last?.createdAt ?? .distantPast) }
        #expect(times == times.sorted(by: >) && times == rows.map(\.time))
        let last = try #require(rows.last).room
        let pushed = Message(id: "new", conversationID: last.id, sender: Person(id: "maria", name: "Maria"), text: "Just now")
        await fake.push(.messageUpserted(pushed))
        try await Task.sleep(for: .milliseconds(50))
        let top = try #require(store.homeRows().first)
        #expect(top.room.id == last.id && top.last?.id == "new" && top.thread == nil)
    }
    @Test func aRowWithoutItsNewestMessageLoadsItOnce() async throws {
        let (store, fake) = await started()
        let room = try #require(store.homeRows().first { $0.last == nil }).room
        let before = await fake.historyRequests
        await store.loadPreview(room.id)
        #expect(await fake.historyRequests == before + 1)
        #expect(store.homeRows().first { $0.room.id == room.id }?.last != nil)
        await store.loadPreview(room.id)   // up to date now
        #expect(await fake.historyRequests == before + 1)
    }
    /// A preview loads in the background: a conversation Google refuses keeps its row without an alert.
    @Test func aRefusedPreviewRaisesNoAlert() async throws {
        let (store, fake) = await started()
        let room = try #require(store.homeRows().first { $0.last == nil }).room
        await fake.simulateRefusedHistory(room.id)
        await store.loadPreview(room.id)
        #expect(store.error == nil)
        await store.load(room.id)   // opening it still says why it's empty
        #expect(store.error != nil)
    }
    /// Home shows the cached list before connecting; that list may be another account's, so previews wait for the account.
    @Test func previewsWaitUntilTheAccountIsKnown() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        let cached = Conversation(id: "space/other-account", name: "Other", kind: .space, members: [], activity: .now)
        store.conversations = [cached]
        await store.loadPreview(cached.id)
        #expect(await fake.historyRequests == 0)
        await store.start()
        let room = try #require(store.homeRows().first { $0.last == nil }).room
        let before = await fake.historyRequests
        await store.loadPreview(room.id)
        #expect(await fake.historyRequests == before + 1)
    }
    /// As web: a conversation whose newest message starts a thread on Home shows only as that thread's row.
    @Test func aConversationIsNotRepeatedAboveItsOwnThread() async throws {
        let (store, _) = await started()
        let rows = store.homeRows()
        let heads = Set(rows.compactMap(\.thread?.id))
        #expect(!heads.isEmpty)
        #expect(!rows.contains { $0.thread == nil && $0.last.map { heads.contains($0.id) } == true })
    }
    @Test func rowTimesReadAsWebsDo() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 6)))
        func at(_ day: Int, _ hour: Int, month: Int = 10, year: Int = 2026) -> Date { calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))! }
        let locale = Locale(identifier: "en_US")
        func time(_ date: Date) -> String { ShortcutList.time(date, now: now, calendar: calendar, locale: locale) }
        #expect(time(at(7, 21)) == "9:00\u{202F}PM")          // within a day: the time
        #expect(time(at(7, 3)) == "Yesterday")
        #expect(time(at(6, 12)) == "Tue")                     // this week: the weekday
        #expect(time(at(12, 9, month: 9)) == "Sep 12")         // this year
        #expect(time(at(3, 9, month: 9, year: 2021)) == "Sep 2021")
    }
    @Test func previewsKeepToOneParagraph() {
        #expect(ShortcutList.oneLine("Este es un mensaje de pruebas.\n\nSorry por el noise  🙏") == "Este es un mensaje de pruebas. Sorry por el noise 🙏")
    }
    @Test func choosingARowOpensTheConversationInPlace() async throws {
        let (store, _) = await started(landing: .home)
        let row = try #require(store.homeRows().first { $0.room.unread > 0 })
        await store.select(row.room.id)
        #expect(store.shortcut == nil && store.selectedID == row.room.id)
        #expect(store.conversations.first { $0.id == row.room.id }?.unread == 0)
    }
    @Test func thePaneListsEveryRowFullWidth() async throws {
        let (store, _) = await started(landing: .home)
        let host = NSHostingView(rootView: ShortcutList(store: store, shortcut: .home).frame(width: 700, height: 600))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        host.layoutSubtreeIfNeeded()
        let table = try #require(Self.table(in: host))
        #expect(table.numberOfRows == store.homeRows().count)
        #expect(table.frame.width >= 650)
    }
    private static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews { if let found = table(in: child) { return found } }
        return nil
    }
}
