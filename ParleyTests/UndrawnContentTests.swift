import Foundation
import Testing
@testable import Parley

/// Content on a message that Parley doesn't draw is reported (logged) rather than silently dropped.
struct UndrawnContentTests {
    private func message(text: String = "hi", _ configure: (inout Dynamite_Message) -> Void = { _ in }) -> Dynamite_Message {
        .with { m in m.id.messageID = "m1"; m.textBody = text; configure(&m) }
    }
    @Test func anUnknownBotResponseTypeIsReported() {
        #expect(DynamiteMapper.undrawn(message { $0.botResponses = [.with { $0.type = 9 }] }, selfID: "me") == ["19.1=9"])
    }
    @Test func handledShapesStayQuiet() {
        #expect(DynamiteMapper.undrawn(message(), selfID: "me").isEmpty)
        #expect(DynamiteMapper.undrawn(message { $0.botResponses = [.with { $0.type = 6; $0.bot.name = "App" }] }, selfID: "me").isEmpty)
        #expect(DynamiteMapper.undrawn(message(text: "") { $0.botResponses = [.with { $0.type = 2 }] }, selfID: "me").isEmpty)
        #expect(DynamiteMapper.undrawn(message { $0.privateMessageViewers = [.with { $0.viewer.id = "me" }] }, selfID: "me").isEmpty)
    }
    @Test func aCardWidgetParleyCannotDrawIsReported() {
        let empty = message { $0.appAttachments = [.with { $0.card.sections = [.with { $0.widgets = [.init()] }] }] }   // e.g. a text input
        #expect(DynamiteMapper.undrawn(empty, selfID: "me") == ["15.7.2.2"])
        let button = message { $0.appAttachments = [.with { $0.card.sections = [.with { $0.widgets = [.with { $0.buttons = [.with { $0.textButton.onClick.action = Data([1]) }] }] }] }] }
        #expect(DynamiteMapper.undrawn(button, selfID: "me").isEmpty)
        // A button Parley drops (icon-only, or one that neither opens a link nor acts) is reported…
        let dropped = message { $0.appAttachments = [.with { $0.card.sections = [.with { $0.widgets = [.with { $0.buttons = [.init()] }] }] }] }
        #expect(DynamiteMapper.undrawn(dropped, selfID: "me") == ["15.7.2.2.8"])
        // …except on Gemini's feedback row, which Google Chat's other clients don't draw either.
        let feedback = message { $0.appAttachments = [.with { $0.attachmentID = "accessory_actions"; $0.card.sections = [.with { $0.widgets = [.with { $0.buttons = [.init()] }] }] }] }
        #expect(DynamiteMapper.undrawn(feedback, selfID: "me").isEmpty)
    }
    @Test func otherHiddenContentIsReported() {
        #expect(DynamiteMapper.undrawn(message { $0.botResponses = [.with { $0.type = 2 }] }, selfID: "me") == ["19.1=2"])   // with text and no required action: not drawn
        #expect(DynamiteMapper.undrawn(message { $0.privateMessageViewers = [.with { $0.viewer.id = "someone" }] }, selfID: "me") == ["35"])
        #expect(DynamiteMapper.undrawn(message { $0.translation.text = "x"; $0.encryptedContent = Data([1]) }, selfID: "me") == ["50"])   // a translation is drawn
    }
}
