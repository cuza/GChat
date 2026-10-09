import Foundation
import Testing
@testable import Parley

/// Message kinds Google Chat sends that Parley drew wrongly or not at all (Research: message coverage).
struct CoverageGapsTests {
    private func message(text: String = "", _ configure: (inout Dynamite_Message) -> Void) -> Dynamite_Message {
        .with { m in m.id.messageID = "m1"; m.id.parentID.topicID.topicID = "t1"; m.creator.userID.id = "alex"; m.textBody = text; m.messageType = .userMessage; configure(&m) }
    }
    private func shown(_ proto: Dynamite_Message) throws -> Message {
        try #require(DynamiteMapper.message(proto, in: "dm/d", selfID: "me", people: [:]))
    }
    private func meet(kind: Int32, _ status: Dynamite_MeetCallMetadata.Status) -> Dynamite_Message {
        message { $0.annotations = [.with { a in
            a.type = .gsuiteIntegration
            a.gsuiteIntegrationMetadata = .with { $0.integrationType = 1; $0.meetCall = .with { c in c.status = status; c.meeting.link = .with { $0.url = "https://meet.google.com/abc-defg-hij"; $0.kind = kind } } }
        }] }
    }

    @Test func callsAndHuddlesAreWordedAsGoogleChatWordsThem() throws {
        #expect(try shown(meet(kind: 2, .callMissed)).attachments.first?.name == "Call missed")
        #expect(try shown(meet(kind: 2, .callEnded)).attachments.first?.name == "Call ended")
        #expect(try shown(meet(kind: 0, .callStarted)).attachments.first?.name == "Call started")
        #expect(try shown(meet(kind: 1, .callStarted)).attachments.first?.name == "Huddle started")
        #expect(try shown(meet(kind: 1, .callEnded)).attachments.first?.name == "Huddle ended")
        #expect(try shown(meet(kind: 1, .callMissed)).attachments.first?.name == "Huddle ended")
    }
    @Test func aDeletedMessageShowsWhoDeletedIt() throws {
        let byAdmin = try shown(message { $0.tombstone.isTombstone = true; $0.tombstoneMetadata.type = 3 })
        #expect(byAdmin.text == "Message deleted by an admin" && !byAdmin.isSystem && byAdmin.attachments.isEmpty)
        #expect(byAdmin.formatting == [TextStyleRange(style: .italic, start: 0, length: (byAdmin.text as NSString).length)])
        #expect(try shown(message { $0.tombstone.isTombstone = true }).text == "Message deleted")
    }
    @Test func aPrivateMessageSaysOnlyYouSeeIt() throws {
        let only = try shown(message(text: "Your report is ready") { $0.privateMessageViewers = [.with { $0.viewer.id = "me" }] })
        #expect(only.via?.contains("Only visible to you") == true && only.text == "Your report is ready")
    }
    @Test func anAppThatCouldNotAnswerSaysSoAndLinksToItsSetup() throws {
        let reply = try shown(message { $0.botResponses = [.with { r in r.setupURL = "https://example.com/setup"; r.bot.name = "Jira" }] })
        #expect(reply.text == "Jira couldn’t respond")
        #expect(reply.attachments.first?.name == "Configure Jira" && reply.attachments.first?.url == URL(string: "https://example.com/setup"))
    }
    @Test func calendarAndTasksChipsShowTheirTitle() throws {
        func calendar(_ first: String, _ second: String) -> Dynamite_Message {
            message { $0.annotations = [.with { a in a.type = .gsuiteIntegration; a.chipRenderType = .render
                a.gsuiteIntegrationMetadata = .with { $0.integrationType = 3; $0.calendar.event = .with { $0.first = first; $0.second = second } } }] }
        }
        for proto in [calendar("Team sync", "https://www.google.com/calendar/event?eid=x"), calendar("https://www.google.com/calendar/event?eid=x", "Team sync")] {
            let chip = try #require(try shown(proto).attachments.first)
            #expect(chip.name == "Team sync" && chip.url?.host() == "www.google.com" && chip.detail == "Google Calendar")
        }
        let task = try shown(message { $0.annotations = [.with { a in a.type = .gsuiteIntegration; a.chipRenderType = .render
            a.gsuiteIntegrationMetadata = .with { $0.integrationType = 2; $0.tasks.task.title = "Send the deck" } }] })
        #expect(task.attachments.first?.name == "Send the deck" && task.attachments.first?.detail == "Google Tasks")
    }
    @Test func cardImagesAndDividersAreDrawn() throws {
        let card = message { $0.appAttachments = [.with { a in a.attachmentID = "c"
            a.card = .with { $0.sections = [.with { $0.widgets = [.with { $0.image = .with { $0.imageURL = "https://example.com/a.png"; $0.aspectRatio = 2 } }, .with { $0.divider = .init() },
                                                                   .with { $0.textParagraph.text = .with { $0.segments = [.with { $0.run.text = "Below" }] } }] }] } }] }
        let items = try #require(try shown(card).attachments.first?.card?.sections.first)
        #expect(items.first == .image(URL(string: "https://example.com/a.png")!, aspect: 2) && items[1] == .divider)
    }
}
