import Foundation
import Testing
@testable import Parley

/// Send a Meet link: Google Chat's server makes the meeting, and Parley posts it as the "Join video meeting" card.
@MainActor struct MeetLinkTests {
    @Test func sendingAMeetLinkPostsTheMeetingAndReturnsItsLink() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        let id = try #require(store.selectedID)
        let url = try #require(await store.sendMeetLink(in: id))
        #expect(url.host() == "meet.google.com")
        let posted = try #require(store.timeline(id, thread: nil).last)
        #expect(posted.sender.id == store.me.id && posted.attachments.first?.call == .join && posted.attachments.first?.url == url)
    }
    @Test func aRefusedMeetLinkSaysSo() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        await fake.simulateSendFailure()
        #expect(await store.sendMeetLink(in: try #require(store.selectedID)) == nil)
        #expect(store.error != nil)
    }
}

/// Network-stubbed: joins the serialized AuthTests suite (the stub registry is global).
extension AuthTests {
    @Test func aMeetLinkIsMadeByTheServerThenSentAsItsAnnotation() async throws {
        let meeting = Dynamite_Annotation.with { a in
            a.type = .videoCall; a.startIndex = 0; a.length = 0; a.chipRenderType = .render
            a.videoCallMetadata.meetingSpace.url = "https://meet.google.com/abc-defg-hij"
        }
        var echo = Self.message("m9", topic: "m9", at: 5, by: "me"); echo.textBody = ""; echo.annotations = [meeting]
        let made = try Self.proto(Dynamite_CreateVideoCallResponse.with { $0.annotation = meeting })
        let topic = try Self.proto(Dynamite_CreateTopicResponse.with { $0.topic.replies = [echo] })
        let (backend, exchange) = try await Self.connected([made, topic])
        let sent = try await backend.sendMeetLink(in: "dm/a")
        let ask = try Dynamite_CreateVideoCallRequest(serializedBytes: Self.body(try #require(exchange.requests.first { $0.url?.path == "/api/create_video_call" })))
        #expect(ask.groupID.dmID.dmID == "a" && ask.hasRequestHeader)
        let post = try Dynamite_CreateTopicRequest(serializedBytes: Self.body(try #require(exchange.requests.first { $0.url?.path == "/api/create_topic" })))
        #expect(post.annotations == [meeting] && post.textBody.isEmpty && post.groupID.dmID.dmID == "a")
        #expect(sent.attachments.first?.call == .join && sent.attachments.first?.url == URL(string: "https://meet.google.com/abc-defg-hij"))
    }
}
