import Foundation
import SwiftProtobuf
import Testing
@testable import Parley

struct ProtoTests {
    private var header: Dynamite_RequestHeader { .with { $0.traceID = 0; $0.clientType = .ios } }

    @Test func identityRequestMatchesLiveVerifiedBytes() throws {
        let request = Dynamite_GetSelfUserStatusRequest.with { $0.requestHeader = header }
        let bytes: Data = try request.serializedBytes()
        #expect(bytes == ProbeWire.identityRequest)
    }
    @Test func worldRequestMatchesLiveVerifiedBytes() throws {
        let request = Dynamite_PaginatedWorldRequest.with {
            $0.requestHeader = header
            $0.worldSectionRequests = [.with { $0.pageSize = 200; $0.paginationToken = "next" }]
            $0.fetchFromUserSpaces = true
            $0.fetchSnippetsForUnnamedRooms = true
        }
        let bytes: Data = try request.serializedBytes()
        #expect(bytes == ProbeWire.worldRequest(cursors: ["next"]))
    }
    @Test func worldResponseDecodesSpikeFixture() throws {
        let room = ProbeWire.message(1, ProbeWire.message(1, ProbeWire.string(1, "space")))
        let section = ProbeWire.message(2, room) + ProbeWire.integer(5, 1) + ProbeWire.string(6, "next")
        let response = try Dynamite_PaginatedWorldResponse(serializedBytes: ProbeWire.message(1, section))
        #expect(response.worldSectionResponses.first?.worldItems.first?.groupID.spaceID.spaceID == "space")
        #expect(response.worldSectionResponses.first?.moreItems == true)
        #expect(response.worldSectionResponses.first?.paginationToken == "next")
    }
    @Test func streamRequestFieldNumbersMatchGoogleChat() throws {
        let acks: Data = try Dynamite_StreamEventsRequest.with { $0.acks = ["a"] }.serializedBytes()
        #expect(acks == ProbeWire.string(7, "a"))
        let session: Data = try Dynamite_StreamEventsRequest.with { $0.clientSessionID = 5 }.serializedBytes()
        #expect(session == ProbeWire.integer(6, 5))
        let ping: Data = try Dynamite_StreamEventsRequest.with { $0.pingEvent.state = .active }.serializedBytes()
        #expect(ping == ProbeWire.message(2, ProbeWire.integer(1, 1)))
    }
    @Test func eventBodiesDecodeKnownAndUnknownTypes() throws {
        let ready = ProbeWire.message(8, ProbeWire.integer(12, 33))
        let unknown = ProbeWire.message(8, ProbeWire.integer(12, 99))
        let posted = ProbeWire.message(8, ProbeWire.integer(12, 6) + ProbeWire.message(6, ProbeWire.message(1, ProbeWire.string(10, "hi"))))
        let event = try Dynamite_Event(serializedBytes: ready + unknown + posted + ProbeWire.message(6, ProbeWire.integer(1, 77)))
        #expect(event.bodies.map(\.eventType) == [.sessionReady, .unknown, .messagePosted])
        #expect(event.bodies[2].messagePosted.message.textBody == "hi")
        #expect(event.userRevision.timestamp == 77)
        let response = try Dynamite_StreamEventsResponse(serializedBytes: ProbeWire.message(1, ready) + ProbeWire.string(2, "s1"))
        #expect(response.sampleID == "s1")
    }
    @Test func writeRequestsUseGoogleChatFieldNumbers() throws {
        let topic: Data = try Dynamite_CreateTopicRequest.with {
            $0.topicAndMessageID = "abc"; $0.historyV2 = true; $0.messageInfo.acceptFormatAnnotations = false
        }.serializedBytes()
        #expect(topic == ProbeWire.string(7, "abc") + ProbeWire.integer(8, 1) + ProbeWire.message(9, ProbeWire.integer(1, 0)))
        let edit: Data = try Dynamite_EditMessageRequest.with { $0.messageID.messageID = "m"; $0.textBody = "t" }.serializedBytes()
        #expect(edit == ProbeWire.message(1, ProbeWire.string(2, "m")) + ProbeWire.string(2, "t"))
        let delete: Data = try Dynamite_DeleteMessageRequest.with { $0.messageID.messageID = "m" }.serializedBytes()
        #expect(delete == ProbeWire.message(1, ProbeWire.string(2, "m")))
        let react: Data = try Dynamite_UpdateReactionRequest.with { $0.emoji.unicode = "👍"; $0.option = .remove }.serializedBytes()
        #expect(react == ProbeWire.message(2, ProbeWire.string(1, "👍")) + ProbeWire.integer(3, 2))
        let older: Data = try Dynamite_ListTopicsRequest.with { $0.filter.olderThan = 5 }.serializedBytes()
        #expect(older == ProbeWire.message(4, ProbeWire.integer(1, 5)))
        let search: Data = try Dynamite_SearchMessagesV2Request.with { $0.size = 20; $0.filter = .init(); $0.query = "q" }.serializedBytes()
        #expect(search == ProbeWire.integer(1, 20) + ProbeWire.message(3, Data()) + ProbeWire.string(4, "q"))
    }
    @Test func readStateAndSearchResponsesDecode() throws {
        let state = try Dynamite_GroupReadState(serializedBytes: ProbeWire.integer(2, 10) + ProbeWire.integer(18, 11) + ProbeWire.integer(29, 12))
        #expect((state.lastReadTime, state.markAsUnreadTimestamp, state.lastHeadMessageCreateTime) == (10, 11, 12))
        let response = try Dynamite_SearchMessagesV2Response(serializedBytes:
            ProbeWire.string(1, "next") + ProbeWire.message(3, ProbeWire.message(1, ProbeWire.message(1, ProbeWire.string(10, "hit")))))
        #expect(response.cursor == "next" && response.results.items.first?.message.textBody == "hit")
    }

    @Test func listTopicsAsksForTopicMetadata() throws {
        let bytes: Data = try Dynamite_ListTopicsRequest.with { $0.fetchOptions = [.topicMetadata] }.serializedBytes()
        #expect(bytes == ProbeWire.integer(5, 4))
    }
}
