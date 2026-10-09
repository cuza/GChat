import AppKit
import Foundation
import Testing
@testable import Parley

/// Messages an app posted on a person's behalf (for example imported history): the app's name is shown after the sender's.
struct AppAttributionTests {
    private let people = ["u1": Person(id: "u1", name: "Maria"), "app9": Person(id: "app9", name: "Import Bot")]
    private func posted(actingApp: String = "") -> Dynamite_Message {
        .with {
            $0.id.parentID.topicID.topicID = "t1"; $0.id.messageID = "m1"; $0.createTime = 5_000_000; $0.textBody = "hi"
            $0.creator.userID.id = "u1"
            if !actingApp.isEmpty { $0.creator.userID.actingUserID = actingApp }
        }
    }

    @Test func theActingAppIsUserIdFieldFour() throws {
        let userID = ProbeWire.string(1, "u1") + ProbeWire.string(4, "app9")
        let bytes = ProbeWire.message(2, ProbeWire.message(1, userID))
        let message = try Dynamite_Message(serializedBytes: bytes)
        #expect(message.creator.userID.id == "u1" && message.creator.userID.actingUserID == "app9")
    }
    @Test func theAppsNameFollowsTheSender() {
        #expect(DynamiteMapper.message(posted(actingApp: "app9"), in: "space/x", selfID: "me", people: people)?.via == "Import Bot")
        // Not looked up (yet): a generic label rather than none.
        #expect(DynamiteMapper.message(posted(actingApp: "app7"), in: "space/x", selfID: "me", people: people)?.via == "App")
        #expect(DynamiteMapper.message(posted(), in: "space/x", selfID: "me", people: people)?.via == nil)
    }
    @Test func actingAppsAreLookedUpSeparately() {
        #expect(DynamiteMapper.appIDs(posted(actingApp: "app9")) == ["app9"])
        #expect(DynamiteMapper.appIDs(posted()).isEmpty)
        #expect(!DynamiteMapper.userIDs(posted(actingApp: "app9")).contains("app9"))
    }
    @Test func cachedMessagesWithoutAnAppDecode() throws {
        let old = #"{"id":"m1","conversationID":"c","sender":{"id":"u","name":"U","presence":"offline"},"text":"hi","createdAt":0,"edited":false,"reactions":[],"delivery":"sent","replyCount":0}"#
        #expect(try JSONDecoder().decode(Message.self, from: Data(old.utf8)).via == nil)
    }

    // MARK: Layout

    private func row(via: String? = "Import Bot", name: String = "Maria", begins: Bool = true) -> TimelineRow {
        var message = Message(id: "m", conversationID: "c", sender: Person(id: "u1", name: name), text: "Hello there",
                              createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        message.via = via
        return TimelineRow(message: message, begins: begins, ends: true, newDay: false)
    }
    @Test func theBadgeSitsAfterTheNameOnItsLine() throws {
        for style in TimelineStyle.allCases {
            let layout = RowLayout.make(row(), width: 700, own: false, kind: .space, style: style)
            let name = try #require(layout.name), badge = try #require(layout.via)
            #expect(badge.minX >= name.maxX + 4 && abs(badge.midY - name.midY) <= 1)
            #expect(layout.bubble.contains(badge) && badge.maxX <= layout.bubble.maxX - RowLayout.padX)
        }
    }
    @Test func aLongNameShrinksToKeepTheBadge() throws {
        let layout = RowLayout.make(row(name: String(repeating: "Maria ", count: 40)), width: 500, own: false, kind: .space)
        let name = try #require(layout.name), badge = try #require(layout.via)
        #expect(badge.minX >= name.maxX && badge.maxX <= layout.bubble.maxX - RowLayout.padX)
    }
    @Test func noBadgeWhereNoNameIsShown() {
        #expect(RowLayout.make(row(), width: 700, own: true, kind: .space).via == nil)
        #expect(RowLayout.make(row(begins: false), width: 700, own: false, kind: .space).via == nil)
        #expect(RowLayout.make(row(), width: 700, own: false, kind: .direct).via == nil)
        #expect(RowLayout.make(row(via: nil), width: 700, own: false, kind: .space).via == nil)
    }
    @MainActor @Test func theRowViewShowsTheBadgeWithATooltip() {
        let view = MessageRowView(frame: NSRect(x: 0, y: 0, width: 700, height: 60))
        view.configure(row(), own: false, kind: .space, meID: "me", actions: MessageRowActions())
        view.layout()
        #expect(!view.viaLabel.isHidden && view.viaLabel.text.string == "Import Bot")
        #expect(view.viaLabel.toolTip == "Posted by Import Bot on Maria’s behalf")
        view.configure(row(via: nil), own: false, kind: .space, meID: "me", actions: MessageRowActions())
        view.layout()
        #expect(view.viaLabel.isHidden)
    }
}

struct SpaceDetailsLineTests {
    private let people = ["me": Person(id: "me", name: "Dave"), "u1": Person(id: "u1", name: "Maria")]
    private func line(_ update: Dynamite_RoomUpdatedMetadata) -> String? {
        let proto = Dynamite_Message.with {
            $0.id.parentID.topicID.topicID = "t1"; $0.id.messageID = "m1"; $0.creator.userID.id = "u1"; $0.createTime = 5_000_000
            $0.textBody = "Space Updated"; $0.messageType = .systemMessage
            $0.annotations = [.with { $0.type = .roomUpdated; $0.roomUpdated = update }]
        }
        return DynamiteMapper.message(proto, in: "space/x", selfID: "me", people: people)?.text
    }
    private func details(_ new: (String, String), _ prev: (String, String) = ("", "")) -> Dynamite_RoomUpdatedMetadata {
        .with { u in
            u.initiator.userID.id = "u1"
            if !new.0.isEmpty { u.groupDetailsMetadata.newGroupDetails.description_p = new.0 }
            if !new.1.isEmpty { u.groupDetailsMetadata.newGroupDetails.guidelines = new.1 }
            if !prev.0.isEmpty { u.groupDetailsMetadata.prevGroupDetails.description_p = prev.0 }
            if !prev.1.isEmpty { u.groupDetailsMetadata.prevGroupDetails.guidelines = prev.1 }
        }
    }

    @Test func detailsDecodeFromFieldNumbers() throws {
        let new = ProbeWire.message(1, ProbeWire.string(1, "New") + ProbeWire.string(2, ""))
        let prev = ProbeWire.message(2, ProbeWire.string(1, "Old"))
        let update = ProbeWire.message(7, new + prev) + ProbeWire.integer(8, 2)
        let annotation = try Dynamite_Annotation(serializedBytes: ProbeWire.integer(1, 14) + ProbeWire.message(14, update))
        #expect(annotation.roomUpdated.groupDetailsMetadata.newGroupDetails.description_p == "New")
        #expect(annotation.roomUpdated.groupDetailsMetadata.prevGroupDetails.description_p == "Old")
        #expect(annotation.roomUpdated.initiatorType == 2)
    }
    @Test func aNewDescriptionIsQuoted() {
        #expect(line(details(("Design and research", ""))) == "Maria updated the space description to:\nDesign and research")
        #expect(line(details(("Now", ""), ("Before", ""))) == "Maria updated the space description to:\nNow")
    }
    @Test func removalsAndGuidelines() {
        #expect(line(details(("", ""), ("Before", ""))) == "Maria removed the space description")
        #expect(line(details(("", "Be kind"))) == "Maria updated the space guidelines")
        #expect(line(details(("", ""), ("", "Be kind"))) == "Maria removed the space guidelines")
        #expect(line(details(("About", "Be kind"))) == "Maria updated the space description to:\nAbout\nMaria updated the space guidelines")
    }
    @Test func anAdminIsNotNamed() {
        var update = details(("About", ""))
        update.initiatorType = 2
        #expect(line(update) == "An admin updated the space description to:\nAbout")
    }
    @Test func nothingChangedIsHidden() {
        #expect(line(details(("Same", ""), ("Same", ""))) == nil)
    }
    @MainActor @Test func aLongDescriptionIsCutWithTheFullTextInATooltip() throws {
        let text = "Maria updated the space description to:\n" + String(repeating: "Design and research at the company. ", count: 60)
        let row = TimelineRow(message: Message(id: "s", conversationID: "c", sender: Person(id: "u1", name: "Maria"), text: text,
                                               createdAt: Date(timeIntervalSince1970: 1_700_000_000), isSystem: true),
                              begins: true, ends: true, newDay: false)
        let pill = try #require(RowLayout.make(row, width: 700, own: false, kind: .space).service)
        let lineHeight = RowLayout.measure(RowLayout.serviceText("A"), width: 600).height
        #expect(pill.height <= lineHeight * CGFloat(RowLayout.serviceLines) + 2 * RowLayout.serviceInset.height + 1)
        #expect(pill.height >= lineHeight * 2)
        let view = MessageRowView(frame: NSRect(x: 0, y: 0, width: 700, height: 200))
        view.configure(row, own: false, kind: .space, meID: "me", actions: MessageRowActions())
        #expect(view.serviceLabel.toolTip == text)
    }
}

extension AuthTests {
    /// The acting app is looked up on its own, as a BOT user, so a refused lookup cannot cost people their names.
    @Test func anActingAppIsLookedUpAsABot() async throws {
        let app = try Self.proto(Dynamite_GetMembersResponse.with {
            $0.memberProfiles = [.with { $0.member.user.userID.id = "app9"; $0.member.user.userID.type = .bot; $0.member.user.name = "Import Bot" }]
        })
        let (backend, exchange) = try await Self.connected([app])
        var posted = Self.message("m1", topic: "t1", at: 1)
        posted.creator.userID.actingUserID = "app9"
        await backend.handle(Self.pushed(.messagePosted, posted))
        let messages = Self.upserts(await Self.drain(backend))
        #expect(messages.first?.via == "Import Bot" && messages.first?.sender.name == "Maria")
        let request = try Dynamite_GetMembersRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(request.membershipIds.map(\.memberID.userID.id) == ["app9"])
        #expect(request.membershipIds.map(\.memberID.userID.type) == [.bot])
    }
}
