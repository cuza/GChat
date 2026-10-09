import Foundation
import SwiftProtobuf
import Testing
@testable import Parley

/// Raw bytes pin the wire layouts, independent of the generated code.
struct TypingPresenceReceiptsWireTests {
    private let dm = ProbeWire.message(3, ProbeWire.string(1, "a"))   // GroupId{dm_id(3){dm_id(1)}}

    @Test func typingRequestIsStateOneAndAGroupOrTopicContext() throws {
        let group = Dynamite_SetTypingStateRequest.with { $0.state = .typing; $0.context.groupID.dmID.dmID = "a" }
        #expect(try group.serializedBytes() == ProbeWire.integer(1, 1) + ProbeWire.message(2, ProbeWire.message(1, dm)))
        let topic = Dynamite_SetTypingStateRequest.with { $0.state = .typing; $0.context.topicID.topicID = "t"; $0.context.topicID.groupID.dmID.dmID = "a" }
        #expect(try topic.serializedBytes() == ProbeWire.integer(1, 1) + ProbeWire.message(2, ProbeWire.message(2, ProbeWire.string(2, "t") + ProbeWire.message(3, dm))))
    }
    @Test func groupSubscriptionIsStreamEventsFieldEight() throws {
        let request = Dynamite_StreamEventsRequest.with { $0.groupSubscriptionEvent.groupIds = [.with { $0.dmID.dmID = "a" }] }
        #expect(try request.serializedBytes() == ProbeWire.message(8, ProbeWire.message(1, dm)))
    }
    @Test func presenceRequestIsUserIDsOnly() throws {
        let request = Dynamite_GetUserPresenceRequest.with { $0.userIds = [.with { $0.id = "u1" }] }
        #expect(try request.serializedBytes() == ProbeWire.message(1, ProbeWire.string(1, "u1")))
    }
    @Test func eventBodiesDecodeFromGoogleChatFieldNumbers() throws {
        let typing = try Dynamite_EventBody(serializedBytes: ProbeWire.integer(12, 29)
            + ProbeWire.message(26, ProbeWire.integer(1, 1) + ProbeWire.message(2, ProbeWire.string(1, "u1")) + ProbeWire.message(3, ProbeWire.message(1, dm)) + ProbeWire.integer(4, 7)))
        #expect(typing.eventType == .typingStateChanged && typing.typingStateChanged.state == .typing)
        #expect(typing.typingStateChanged.userID.id == "u1" && typing.typingStateChanged.context.groupID.dmID.dmID == "a" && typing.typingStateChanged.startTimestampUsec == 7)

        let receipt = ProbeWire.integer(2, 99) + ProbeWire.message(3, ProbeWire.message(1, ProbeWire.string(1, "u1")))
        let receipts = try Dynamite_EventBody(serializedBytes: ProbeWire.integer(12, 36)
            + ProbeWire.message(33, ProbeWire.message(1, dm) + ProbeWire.message(2, ProbeWire.integer(1, 1) + ProbeWire.message(2, receipt))))
        #expect(receipts.eventType == .readReceiptChanged && receipts.readReceiptChanged.readReceiptSet.enabled)
        #expect(receipts.readReceiptChanged.readReceiptSet.readReceipts.first?.lastReadTimestampMicros == 99)
        #expect(receipts.readReceiptChanged.readReceiptSet.readReceipts.first?.user.userID.id == "u1")

        let status = ProbeWire.message(1, ProbeWire.string(1, "u1")) + ProbeWire.message(2, ProbeWire.integer(1, 2)) + ProbeWire.integer(5, 1)
            + ProbeWire.message(6, ProbeWire.string(1, "Lunch") + ProbeWire.message(4, ProbeWire.string(1, "🥪")))
        let updated = try Dynamite_EventBody(serializedBytes: ProbeWire.integer(12, 25) + ProbeWire.message(23, ProbeWire.message(1, status)))
        #expect(updated.eventType == .userStatusUpdatedEvent && updated.userStatusUpdated.userStatus.dndSettings.dndState == .dnd)
        #expect(updated.userStatusUpdated.userStatus.customStatus.statusText == "Lunch" && updated.userStatusUpdated.userStatus.customStatus.emoji.unicode == "🥪")
        #expect(updated.userStatusUpdated.userStatus.presenceShared)
    }
    @Test func presenceAndReceiptResponsesDecode() throws {
        let presence = try Dynamite_GetUserPresenceResponse(serializedBytes: ProbeWire.message(1,
            ProbeWire.message(1, ProbeWire.string(1, "u1")) + ProbeWire.integer(2, 1) + ProbeWire.integer(3, 2) + ProbeWire.message(5, ProbeWire.message(6, ProbeWire.string(1, "Busy")))))
        let first = try #require(presence.userPresences.first)
        #expect(first.userID.id == "u1" && first.presence == .active && first.dndState == .dnd && first.userStatus.customStatus.statusText == "Busy")
        let topics = try Dynamite_ListTopicsResponse(serializedBytes: ProbeWire.message(6, ProbeWire.integer(1, 1)))
        #expect(topics.hasReadReceiptSet && topics.readReceiptSet.enabled)
    }
}
