import Foundation
import SwiftProtobuf
import Testing
@testable import Parley

/// Pin, mute, mark as unread and leave from the sidebar, as the requests Google Chat sends; network-stubbed.
extension AuthTests {
    /// GroupId {space_id(1) {space_id(1) "s1"}}.
    private static let spaceS1 = Data([0x0A, 0x04, 0x0A, 0x02, 0x73, 0x31])
    private static func sentBodies(_ exchange: StubExchange, _ path: String) -> [Data] {
        exchange.requests.filter { $0.url?.path == "/api/\(path)" }.map(Self.body)
    }
    /// The sidebar read for one space, so the backend learns its notification level and read markers.
    private static func world(_ readState: Dynamite_GroupReadState, sort: Int64 = 0) throws -> StubExchange.Reply {
        try proto(Dynamite_PaginatedWorldResponse.with {
            $0.worldItems = [.with { $0.groupID.spaceID.spaceID = "s1"; $0.roomName = "Design"; $0.sortTimestamp = sort; $0.readState = readState }]
        })
    }

    /// star_group {group_id(1), starred(2), header(100)}; unpinning sends starred = false explicitly.
    @Test func pinStarsTheGroup() async throws {
        let done = try Self.proto(Dynamite_StarGroupResponse())
        let (backend, exchange) = try await Self.connected([done, done])
        try await backend.setPinned(true, conversation: "space/s1")
        try await backend.setPinned(false, conversation: "space/s1")
        let bodies = Self.sentBodies(exchange, "star_group")
        #expect(bodies.count == 2)
        #expect(bodies.first?.starts(with: Data([0x0A, 0x06]) + Self.spaceS1 + Data([0x10, 0x01])) == true)
        #expect(bodies.last?.starts(with: Data([0x0A, 0x06]) + Self.spaceS1 + Data([0x10, 0x00])) == true)
        #expect(try Dynamite_StarGroupRequest(serializedBytes: try #require(bodies.first)).hasRequestHeader)
    }

    /// update_group_notification_settings {group_id(1), settings(2) {level(2), mute_settings(3) {state(1)}}}:
    /// muting keeps the level the sidebar read reported (here NOTIFY_LESS = 2).
    @Test func muteKeepsTheNotificationLevel() async throws {
        let state = Dynamite_GroupReadState.with { $0.notificationSettings.level = .notifyLess }
        let done = try Self.proto(Dynamite_UpdateGroupNotificationSettingsResponse())
        let (backend, exchange) = try await Self.connected([try Self.world(state), done, done])
        _ = try await backend.conversations()
        try await backend.setMuted(true, conversation: "space/s1")
        try await backend.setMuted(false, conversation: "space/s1")
        let bodies = Self.sentBodies(exchange, "update_group_notification_settings")
        #expect(bodies.first?.starts(with: Data([0x0A, 0x06]) + Self.spaceS1 + Data([0x12, 0x06, 0x10, 0x02, 0x1A, 0x02, 0x08, 0x02])) == true)
        #expect(bodies.last?.starts(with: Data([0x0A, 0x06]) + Self.spaceS1 + Data([0x12, 0x06, 0x10, 0x02, 0x1A, 0x02, 0x08, 0x01])) == true)
    }
    @Test func muteWithoutAKnownLevelSendsNotifyAlways() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_UpdateGroupNotificationSettingsResponse())])
        try await backend.setMuted(true, conversation: "space/s1")
        let body = try #require(Self.sentBodies(exchange, "update_group_notification_settings").first)
        #expect(body.starts(with: Data([0x0A, 0x06]) + Self.spaceS1 + Data([0x12, 0x06, 0x10, 0x00, 0x1A, 0x02, 0x08, 0x02])))
    }
    @Test func mutedComesFromTheServer() throws {
        let item = Dynamite_WorldItemLite.with { $0.groupID.spaceID.spaceID = "s1"; $0.roomName = "Design"; $0.readState.notificationSettings.muteSettings.state = .muted }
        #expect(DynamiteMapper.conversation(item, selfID: "me", people: [:])?.muted == true)
        var unmuted = item; unmuted.readState.notificationSettings.muteSettings.state = .unmuted
        #expect(DynamiteMapper.conversation(unmuted, selfID: "me", people: [:])?.muted == false)
    }

    /// set_mark_as_unread_timestamp {group_id(1), timestamp(2)}: just before the newest message, as Google Chat sends it,
    /// so that message shows unread. Reading the conversation again clears it with 0.
    @Test func markUnreadSetsTheTimestampAndReadingClearsIt() async throws {
        let state = Dynamite_GroupReadState.with { $0.lastHeadMessageCreateTime = 1_700_000_000_000_500; $0.lastReadTime = 1_700_000_000_000_500 }
        let unread = try Self.proto(Dynamite_SetMarkAsUnreadTimestampResponse())
        let (backend, exchange) = try await Self.connected([try Self.world(state, sort: 1_700_000_000_000_600), unread,
                                                            try Self.proto(Dynamite_MarkGroupReadstateResponse()), unread,
                                                            try Self.proto(Dynamite_MarkGroupReadstateResponse())])
        _ = try await backend.conversations()
        try await backend.markUnread("space/s1")
        try await backend.markRead("space/s1")
        try await backend.markRead("space/s1")   // nothing left to clear
        let sent = try Self.sentBodies(exchange, "set_mark_as_unread_timestamp").map { try Dynamite_SetMarkAsUnreadTimestampRequest(serializedBytes: $0) }
        #expect(sent.map(\.markAsUnreadTimestamp) == [1_700_000_000_000_499, 0])
        #expect(sent.allSatisfy { $0.hasMarkAsUnreadTimestamp && $0.groupID.spaceID.spaceID == "s1" && $0.hasRequestHeader })
        #expect(Self.sentBodies(exchange, "set_mark_as_unread_timestamp").first?.starts(with: Data([0x0A, 0x06]) + Self.spaceS1 + Data([0x10])) == true)
    }
    /// A conversation the server still has marked unread is cleared on the next read, even after a relaunch.
    @Test func aServerUnreadMarkIsClearedOnRead() async throws {
        let state = Dynamite_GroupReadState.with { $0.markAsUnreadTimestamp = 1_700_000_000_000_499 }
        let (backend, exchange) = try await Self.connected([try Self.world(state), try Self.proto(Dynamite_MarkGroupReadstateResponse()),
                                                            try Self.proto(Dynamite_SetMarkAsUnreadTimestampResponse())])
        let rooms = try await backend.conversations()
        #expect(rooms.first?.unread == 1)   // survives a refresh: the server's mark keeps it unread
        try await backend.markRead("space/s1")
        let sent = try Self.sentBodies(exchange, "set_mark_as_unread_timestamp").map { try Dynamite_SetMarkAsUnreadTimestampRequest(serializedBytes: $0) }
        #expect(sent.map(\.markAsUnreadTimestamp) == [0])
    }

    /// remove_memberships {member_ids(1) [{user_id(1) {id(1) "me"}}], group_id(2)}: Google Chat's leave.
    @Test func leaveRemovesMyMembership() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_RemoveMembershipsResponse.with { $0.results = [.init()] })])
        try await backend.leave("space/s1")
        let body = try #require(Self.sentBodies(exchange, "remove_memberships").first)
        #expect(body.starts(with: Data([0x0A, 0x06, 0x0A, 0x04, 0x0A, 0x02, 0x6D, 0x65, 0x12, 0x06]) + Self.spaceS1))
        #expect(try Dynamite_RemoveMembershipsRequest(serializedBytes: body).hasRequestHeader)
    }
    @Test func aRefusedLeaveThrows() async throws {
        let refused = Dynamite_RemoveMembershipsResponse.with { $0.results = [.with { $0.failureReason = 3 }] }
        let (backend, _) = try await Self.connected([try Self.proto(refused)])
        await #expect(throws: DynamiteError.leaveRefused) { try await backend.leave("space/s1") }
    }
}
