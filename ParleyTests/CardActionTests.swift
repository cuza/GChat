import Foundation
import SwiftProtobuf
import Testing
@testable import Parley

/// A card's buttons that act (Reply, Resolve on a Drive comment) send the action and the card's inputs back to the app
/// with `click_card`, as Google Chat does; the app answers with the message, its card updated.
struct CardActionTests {
    static let reply = Data(try! Dynamite_CardAction.with { $0.function = "REPLY_TO_COMMENT" }.serializedBytes() as [UInt8])
    static let dialog = Data(try! Dynamite_CardAction.with { $0.function = "list_settings"; $0.interaction = 1 }.serializedBytes() as [UInt8])
    private func text(_ string: String) -> Dynamite_FormattedText { .with { $0.segments = [.with { $0.run.text = string }] } }
    private func mapped(_ widgets: [Dynamite_CardWidget]) throws -> Card {
        let proto = Dynamite_Message.with { m in
            m.id.messageID = "m1"; m.id.parentID.topicID.topicID = "m1"; m.creator.userID.id = "drive"; m.textBody = "A comment"
            m.appAttachments = [.with { $0.card.sections = [.with { $0.widgets = widgets }] }]
        }
        return try #require(DynamiteMapper.message(proto, in: "dm/d", selfID: "me", people: [:])?.attachments.first?.card)
    }
    @Test func aTextInputIsDrawnAndAButtonCarriesItsAction() throws {
        let input = Dynamite_CardWidget.with { $0.textInput = .with { $0.name = "REPLY_TO_COMMENT"; $0.label = "Reply"; $0.value = "" } }
        let buttons = Dynamite_CardWidget.with { $0.buttons = [
            .with { $0.textButton = .with { $0.label = text("Reply"); $0.onClick.action = Self.reply } },
            .with { $0.textButton = .with { $0.label = text("Sign in"); $0.onClick.action = Self.dialog } },
        ] }
        let card = try mapped([input, buttons])
        let chat = try #require(ChatLink.url(message: "dm/d/m1/m1"))
        #expect(card.sections == [[.input(name: "REPLY_TO_COMMENT", label: "Reply", value: ""),
                                   .links([Card.Link(title: "Reply", url: chat, action: Self.reply),
                                           Card.Link(title: "Sign in", url: chat)])]])   // a dialog needs Google Chat
        #expect(Card(sections: card.sections).inputs == [Card.Input(name: "REPLY_TO_COMMENT", value: "")])
        #expect(DynamiteMapper.undrawn(.with { $0.appAttachments = [.with { $0.card.sections = [.with { $0.widgets = [input] }] }] }, selfID: "me").isEmpty)
    }
    @MainActor @Test func theStoreAppliesTheAnsweredMessage() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        let message = try #require(store.messages.first)
        await store.clickCard(message, action: Self.reply, inputs: [Card.Input(name: "REPLY_TO_COMMENT", value: "Thanks")])
        #expect(await fake.cardClicks.last == "\(message.id) REPLY_TO_COMMENT=Thanks")
        #expect(store.messages.first { $0.id == message.id }?.edited == true && store.error == nil)
        await fake.simulateChangeFailure()
        await store.clickCard(message, action: Self.reply, inputs: [])
        #expect(store.error != nil)
    }
}

extension AuthTests {
    @Test func clickCardSendsTheActionAndInputsAsGoogleChatDoes() async throws {
        var answered = Self.message("h1", topic: "t1", at: 1); answered.lastEditTime = 2
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_ClickCardResponse.with { $0.field1 = 1; $0.message = answered })])
        let updated = try await backend.clickCard("dm/a/t1/h1", action: CardActionTests.reply, inputs: [Card.Input(name: "REPLY_TO_COMMENT", value: "parley test")])
        let request = try #require(exchange.requests.last)
        #expect(request.url?.path == "/api/click_card")
        let sent = try Dynamite_ClickCardRequest(serializedBytes: Self.body(request))
        #expect(sent.messageID.messageID == "h1" && sent.messageID.parentID.topicID.topicID == "t1"
                && sent.messageID.parentID.topicID.groupID.dmID.dmID == "a")
        #expect(sent.action == CardActionTests.reply)   // as the button carried it
        #expect(sent.formInputs == [.with { $0.name = "REPLY_TO_COMMENT"; $0.value = "parley test"; $0.field4 = 1 }])
        #expect(sent.hasField4 && sent.field4 == "")
        // Fields 1–4 exactly as Google Chat's web client sends them (its JSON form, in binary), then the header.
        var expected = Dynamite_ClickCardRequest.with { $0.messageID = sent.messageID; $0.action = CardActionTests.reply
            $0.formInputs = sent.formInputs; $0.field4 = "" }
        expected.requestHeader = sent.requestHeader
        #expect(try Self.body(request) == Data(expected.serializedBytes() as [UInt8]))
        #expect(updated?.id == "dm/a/t1/h1" && updated?.edited == true)
    }
}
