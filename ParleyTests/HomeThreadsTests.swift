import AppKit
import Foundation
import SwiftProtobuf
import SwiftUI
import Testing
@testable import Parley

/// Home's thread rows: topics Google Chat sends with the conversation list (paginated_world field 7).
struct HomeThreadMappingTests {
    private static func varint(_ value: UInt64) -> [UInt8] {
        var value = value, bytes: [UInt8] = []
        repeat { var byte = UInt8(value & 0x7F); value >>= 7; if value > 0 { byte |= 0x80 }; bytes.append(byte) } while value > 0
        return bytes
    }
    private static func field(_ number: UInt64, _ bytes: [UInt8]) -> [UInt8] { varint(number << 3 | 2) + varint(UInt64(bytes.count)) + bytes }
    private static func field(_ number: UInt64, int value: UInt64) -> [UInt8] { varint(number << 3) + varint(value) }
    private static func dmMessage(_ id: String, at: Int64, by user: String) -> Dynamite_Message {
        var message = AuthTests.message(id, topic: "t1", at: at, by: user)
        message.id.parentID.topicID.groupID.dmID.dmID = "d"
        return message
    }

    /// As captured: response field 7 = ShortcutItem { 1 Topic { 1 TopicId {2 topic, 3 GroupId}, 2 sort_time,
    /// 7 [head, newest reply], 11 TopicReadState { 2 last_read_time } } }, one level each.
    @Test func aCapturedShapeTopicBecomesAnUnreadThread() throws {
        let topicID: [UInt8] = try Dynamite_TopicId.with { $0.topicID = "t1"; $0.groupID.dmID.dmID = "d" }.serializedBytes()
        let head: [UInt8] = try Self.dmMessage("t1", at: 1_000, by: "me").serializedBytes()
        let reply: [UInt8] = try Self.dmMessage("r1", at: 3_000_000, by: "u1").serializedBytes()
        let readState = Self.field(2, int: 2_000_000) + Self.field(8, int: 3_000_001)
        let topic = Self.field(1, topicID) + Self.field(2, int: 3_000_000) + Self.field(7, head) + Self.field(7, reply) + Self.field(11, readState)
        let response = try Dynamite_PaginatedWorldResponse(serializedBytes: Self.field(7, Self.field(1, topic)))
        let proto = try #require(response.shortcutItems.first?.topic)
        let thread = try #require(DynamiteMapper.homeThread(proto, selfID: "me", people: ["u1": Person(id: "u1", name: "Maria")]))
        #expect(thread.id == "dm/d/t1/t1" && thread.conversationID == "dm/d")
        #expect(thread.head.id == "dm/d/t1/t1" && thread.latest.id == "dm/d/t1/r1" && thread.latest.threadID == thread.id)
        #expect(thread.latest.sender.name == "Maria")
        #expect(thread.unread && thread.time == Date(timeIntervalSince1970: 3))
    }
    @Test func aThreadReadUpToItsNewestReplyIsRead() throws {
        let topic = Dynamite_Topic.with {
            $0.id.topicID = "t1"; $0.id.groupID.dmID.dmID = "d"; $0.sortTime = 3_000_000
            $0.replies = [Self.dmMessage("t1", at: 1_000, by: "u1"), Self.dmMessage("r1", at: 3_000_000, by: "u1")]
            $0.topicReadState.lastReadTime = 3_000_000
        }
        #expect(DynamiteMapper.homeThread(topic, selfID: "me", people: [:])?.unread == false)
        var mine = topic
        mine.topicReadState.lastReadTime = 0
        mine.replies = [Self.dmMessage("t1", at: 1_000, by: "me"), Self.dmMessage("r1", at: 3_000_000, by: "me")]
        #expect(DynamiteMapper.homeThread(mine, selfID: "me", people: [:])?.unread == false)   // my own replies are never unread
    }
    /// The starred message comes back as a one-message topic too: without a reply it is not a thread row.
    @Test func aTopicWithoutRepliesIsNoThread() {
        let topic = Dynamite_Topic.with { $0.id.topicID = "t1"; $0.id.groupID.dmID.dmID = "d"; $0.replies = [Self.dmMessage("t1", at: 1, by: "u1")] }
        #expect(DynamiteMapper.homeThread(topic, selfID: "me", people: [:]) == nil)
    }
}

extension AuthTests {
    /// Home's four sections, as Google Chat's web client sends them: page 30, filter, topic filter (9),
    /// topic option (10) {1 {1: 1, 2: true}, 2 {1: true}}, sort key (11) {1: SORT_BY_SORT_TIME_DESC}, view (15) {1: HOME}.
    @Test func worldAsksForHomesSections() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_PaginatedWorldResponse())])
        _ = try await backend.conversations()
        let body = Self.body(try #require(exchange.requests.last { $0.url?.path == "/api/paginated_world" }))
        let sent = try Dynamite_PaginatedWorldRequest(serializedBytes: body)
        let home = sent.worldSectionRequests.filter { $0.view.view == 1 }
        #expect(home.count == 4)
        #expect(home.allSatisfy { $0.pageSize == 30 && $0.sortKey.sort == 1 && $0.topicOption.page.field1 == 1 && $0.topicOption.page.field2 && $0.topicOption.flag.field1 })
        #expect(home.map(\.topicFilter.labels.count) == [1, 2, 1, 2] && home.map(\.topicFilter.field1) == [0, 1, 0, 1])
        #expect(home[0].worldFilter.muteState == 1 && home[0].worldFilter.excludeLabels.map(\.type) == [3])
        #expect(home[1].worldFilter.readState == 4 && home[1].worldFilter.includeLabels.map(\.type) == [5])
        #expect(home[2].worldFilter.flag17 && home[3].worldFilter.flag17)
        // The first section's tail, byte for byte: 9 {2 {1: 1}, 4: true}, 10 {1 {1: 1, 2: true}, 2 {1: true}}, 11 {1: 1}, 15 {1: 1}.
        let tail = Data([0x4A, 0x06, 0x12, 0x02, 0x08, 0x01, 0x20, 0x01, 0x52, 0x0A, 0x0A, 0x04, 0x08, 0x01, 0x10, 0x01, 0x12, 0x02, 0x08, 0x01,
                         0x5A, 0x02, 0x08, 0x01, 0x7A, 0x02, 0x08, 0x01])
        #expect(body.range(of: tail) != nil)
    }
    /// Checked live: Home's threads come back only with the last section, sort 4 and the constraint "label" = "100G":
    /// 16 {1 {1: 3, 2 {5 {1: 2, 2 {8: "label"}, 3 {8: "100G"}}}}}, byte for byte as the web client encodes it.
    @Test func worldAsksForTheFollowedThreadsSection() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_PaginatedWorldResponse())])
        _ = try await backend.conversations()
        let body = Self.body(try #require(exchange.requests.last { $0.url?.path == "/api/paginated_world" }))
        let sent = try Dynamite_PaginatedWorldRequest(serializedBytes: body)
        let followed = try #require(sent.worldSectionRequests.first { $0.sortKey.sort == 4 })
        #expect(followed.pageSize == 30 && !followed.hasWorldFilter && followed.topicOption.page.field2)
        let constraint: [UInt8] = [0x82, 0x01, 0x1B, 0x0A, 0x19, 0x08, 0x03, 0x12, 0x15, 0x2A, 0x13, 0x08, 0x02,
                                   0x12, 0x07, 0x42, 0x05] + Array("label".utf8) + [0x1A, 0x06, 0x42, 0x04] + Array("100G".utf8)
        #expect(body.range(of: Data(constraint)) != nil)
    }
    @Test func theWorldsTopicsBecomeHomeThreads() async throws {
        let reply = Dynamite_Topic.with {
            $0.id.topicID = "t1"; $0.id.groupID.spaceID.spaceID = "x"; $0.sortTime = 5_000_000
            $0.replies = [Self.message("t1", topic: "t1", at: 1_000_000, by: "me"), Self.message("r1", topic: "t1", at: 5_000_000)]
        }
        let lone = Dynamite_Topic.with { $0.id.topicID = "t2"; $0.id.groupID.spaceID.spaceID = "x"; $0.replies = [Self.message("t2", topic: "t2", at: 1)] }
        let world = Dynamite_PaginatedWorldResponse.with {
            $0.worldItems = [.with { $0.groupID.spaceID.spaceID = "x"; $0.roomName = "Engineering"; $0.sortTimestamp = 5_000_000 }]
            $0.shortcutItems = [.with { $0.topic = reply }, .with { $0.topic = lone }, .with { $0.message = Self.message("t2", topic: "t2", at: 1) }]
        }
        let (backend, _) = try await Self.connected([try Self.proto(world)])
        _ = try await backend.conversations()
        let threads = await backend.homeThreads()
        #expect(threads.map(\.id) == ["space/x/t1/t1"])
        #expect(threads.first?.latest.text == "r1" && threads.first?.unread == true)
    }
}

@MainActor
struct HomeThreadsStoreTests {
    private func started() async -> (ChatStore, FakeBackend) {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        store.shortcut = .home
        await store.start()
        return (store, fake)
    }
    @Test func threadRowsInterleaveWithConversationsByTime() async throws {
        let (store, _) = await started()
        let rows = store.homeRows()
        let threads = rows.compactMap(\.thread)
        #expect(threads.count >= 2 && rows.contains { $0.thread == nil })
        #expect(rows.map(\.time) == rows.map(\.time).sorted(by: >))
        // A conversation keeps its own row next to its thread's row, and that row's message is from its timeline, not the thread.
        for thread in threads {
            #expect(rows.contains { $0.thread == nil && $0.room.id == thread.conversationID })
        }
        #expect(rows.filter { $0.thread == nil }.allSatisfy { $0.last?.threadID == nil })
        #expect(Set(rows.map(\.id)).count == rows.count)
    }
    @Test func filtersKeepUnreadRowsOrThreadRows() async throws {
        let (store, _) = await started()
        let unread = store.homeRows(unreadOnly: true)
        #expect(!unread.isEmpty && unread.allSatisfy(\.unread))
        #expect(unread.contains { $0.thread != nil } && unread.contains { $0.thread == nil })
        let threads = store.homeRows(threadsOnly: true)
        #expect(!threads.isEmpty && threads.allSatisfy { $0.thread != nil })
        #expect(store.homeRows(unreadOnly: true, threadsOnly: true).allSatisfy { $0.unread && $0.thread != nil })
        // The list follows the store's filters, which last the session.
        store.homeThreadsOnly = true
        let host = NSHostingView(rootView: ShortcutList(store: store, shortcut: .home).frame(width: 700, height: 600))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        host.layoutSubtreeIfNeeded()
        #expect(Self.table(in: host)?.numberOfRows == threads.count)
    }
    @Test func openingAThreadRowKeepsHomeAndOpensItsThreadAtTheLatestReply() async throws {
        let (store, fake) = await started()
        let thread = try #require(store.homeRows().compactMap(\.thread).first { $0.unread })
        let before = await fake.markedRead
        await store.openHomeThread(thread)
        #expect(store.shortcut == .home)
        #expect(store.selectedID == thread.conversationID && store.threadID == thread.id && store.highlightedID == thread.latest.id)
        #expect(store.timeline(thread.conversationID, thread: thread.id).contains { $0.id == thread.latest.id })
        #expect(store.homeRows().first { $0.id == thread.id }?.unread == false)
        #expect(await fake.markedRead == before)   // the conversation itself is not marked read
        // Another thread row swaps the pane; a conversation row closes it and leaves Home.
        let other = try #require(store.homeRows().compactMap(\.thread).first { $0.id != thread.id })
        await store.openHomeThread(other)
        #expect(store.shortcut == .home && store.threadID == other.id)
        await store.select(thread.conversationID)
        #expect(store.shortcut == nil && store.threadID == nil)
    }
    @Test func aPushedReplyMovesItsThreadRowUp() async throws {
        let (store, fake) = await started()
        let thread = try #require(store.homeRows().compactMap(\.thread).last)
        let reply = Message(id: "pushed", conversationID: thread.conversationID, threadID: thread.id, sender: Person(id: "alex", name: "Alex"), text: "New reply")
        await fake.push(.messageUpserted(reply))
        try await Task.sleep(for: .milliseconds(50))
        let top = try #require(store.homeRows().first)
        #expect(top.id == thread.id && top.last?.id == "pushed" && top.unread)
    }
    @Test func aThreadRowLaysOutWithItsTwoLines() async throws {
        let (store, _) = await started()
        let (host, window) = Self.hosted(ShortcutList(store: store, shortcut: .home), width: 700)
        defer { window.close() }
        let table = try #require(Self.table(in: host))
        let rows = store.homeRows()
        #expect(table.numberOfRows == rows.count)
        let threadRow = try #require(rows.firstIndex { $0.thread != nil }), roomRow = try #require(rows.firstIndex { $0.thread == nil })
        #expect(table.rect(ofRow: threadRow).height > table.rect(ofRow: roomRow).height)   // first message plus "└ reply"
        #expect(table.frame.width >= 650)
    }
    /// In a window, so the list measures its rows.
    private static func hosted(_ view: some View, width: CGFloat) -> (NSHostingView<AnyView>, NSWindow) {
        let host = NSHostingView(rootView: AnyView(view))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        return (host, window)
    }
    @Test func homeKeepsItsListBesideAnOpenThreadPane() async throws {
        let saved = UserDefaults.standard.object(forKey: "sidePaneWidth")   // the user's own dragged width
        UserDefaults.standard.removeObject(forKey: "sidePaneWidth")
        defer { UserDefaults.standard.set(saved, forKey: "sidePaneWidth") }
        let (store, _) = await started()
        let thread = try #require(store.homeRows().compactMap(\.thread).first)
        await store.openHomeThread(thread)
        let (host, window) = Self.hosted(HomePane(store: store), width: 900)
        defer { window.close() }
        let tables = Self.tables(in: host)
        let list = try #require(tables.first { $0.numberOfRows == store.homeRows().count })
        #expect(list.frame.width >= 900 - ChatView.paneWidth - 60)
        // The thread pane's own timeline sits to the right of the list.
        let pane = try #require(tables.first { $0 !== list })
        #expect(pane.convert(pane.bounds, to: host).minX >= list.convert(list.bounds, to: host).maxX)
        store.threadID = nil
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        #expect(Self.tables(in: host).count == 1)
    }
    private static func table(in view: NSView) -> NSTableView? { tables(in: view).first }
    private static func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
    }
}
