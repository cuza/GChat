import Foundation
import Testing
@testable import Parley

/// Read-only cards: an app or integration message's card becomes formatted text in its bubble.
struct CardTests {
    private func text(_ string: String, italic: Bool = false, bold: Bool = false) -> Dynamite_FormattedText {
        .with { $0.segments = [.with { $0.run = .with { r in r.text = string; if italic { r.styles = [.italic] }; if bold { r.weight = 2 } } }] }
    }
    private func link(_ url: String) -> Dynamite_CardOnClick { .with { $0.openLink = .with { $0.url = "https://www.google.com/url?q=x"; $0.originalURL = url } } }
    private func message(card: Dynamite_Card, body: String = "", id: String = "c1") -> Dynamite_Message {
        .with { m in
            m.id.messageID = "m1"; m.id.parentID.topicID.topicID = "m1"; m.textBody = body; m.creator.userID.id = "drive"
            m.appAttachments = [.with { $0.card = card; $0.attachmentID = id }]
        }
    }
    private func mapped(_ proto: Dynamite_Message) throws -> Message {
        try #require(DynamiteMapper.message(proto, in: "dm/d", selfID: "me", people: [:]))
    }

    /// As Google Chat shows a Drive notice: the notice text in the bubble, and under it the card, a section at a time:
    /// the file row (opening the file), the comment, the author with their avatar, then only the buttons that open a link.
    @Test func aDriveNoticeKeepsItsTextAndShowsItsCard() throws {
        let avatar = "https://lh3.example.com/a/photo"
        let card = Dynamite_Card.with { c in
            c.sections = [
                .with { $0.widgets = [.with { $0.decoratedText = .with { $0.text = text("Plan"); $0.onClick = link("https://docs.example.com/d/1")
                    $0.icon = .with { $0.url = "https://www.gstatic.com/docs.png" } } }] },
                .with { $0.widgets = [.with { $0.textParagraph = .with { $0.text = text("Looks good", italic: true) } }] },
                .with { $0.widgets = [.with { $0.decoratedText = .with { $0.topLabel = text("Alex (alex@example.com)"); $0.text = text("Agreed")
                    $0.icon = .with { $0.url = avatar; $0.imageType = 2 } } }] },
                .with { $0.widgets = [.with { $0.columns = .with { $0.columns = [.with { $0.widgets = [.with { $0.buttons = [
                    .with { $0.textButton = .with { $0.label = text("Reply"); $0.onClick = .with { $0.action = Data([1]) } } },
                    .with { $0.textButton = .with { $0.label = text("Open"); $0.onClick = link("https://docs.example.com/d/1") } },
                ] }] }] } }] },
            ]
        }
        var proto = message(card: card, body: "Alex mentioned you in Plan")
        proto.annotations = [.with { a in a.type = .driveDoc; a.startIndex = 22; a.length = 4; a.driveMetadata.title = "Plan" }]
        let shown = try mapped(proto)
        #expect(shown.text == "Alex mentioned you in Plan")
        #expect(shown.attachments.count == 1)   // the card; the file is in it, not in a second chip
        let drawn = try #require(shown.attachments.first?.card)
        let file = URL(string: "https://docs.example.com/d/1")!
        #expect(drawn.sections == [
            [.row(icon: URL(string: "https://www.gstatic.com/docs.png"), round: false, label: nil, text: "Plan", formatting: [TextStyleRange(style: .nowrap, start: 0, length: 4)], open: file)],   // one line; the row opens the file, its text no link
            [.text("Looks good", [TextStyleRange(style: .italic, start: 0, length: 10)])],
            [.row(icon: URL(string: avatar), round: true, label: "Alex (alex@example.com)", text: "Agreed", formatting: [TextStyleRange(style: .nowrap, start: 0, length: 6)])],
            // Reply sends an action to the app: it opens the message in Google Chat, where that works.
            [.links([Card.Link(title: "Reply", url: ChatLink.url(message: shown.id)!), Card.Link(title: "Open", url: file)])],
        ])
        #expect(shown.attachments.first?.name == "Plan")   // what Home and notifications summarise it as
    }
    /// An app's welcome message in its DM: the text, and a card whose only button sends an action to the app
    /// ("Sign in"). Parley can't send it, so the button opens the message in Google Chat.
    @Test func anActionButtonOpensTheMessageInGoogleChat() throws {
        let card = Dynamite_Card.with { $0.sections = [.with { $0.widgets = [.with { $0.buttons = [
            .with { $0.textButton = .with { $0.label = text("Sign in"); $0.onClick = .with { $0.action = Data([10, 4, 0x6C, 0x69, 0x73, 0x74, 0x40, 1]) } } },   // interaction 1: a dialog
        ] }] }] }
        let shown = try mapped(message(card: card, body: "Connect your account. To get started, click *Sign in*."))
        #expect(shown.attachments.first?.card?.sections == [[.links([Card.Link(title: "Sign in", url: ChatLink.url(message: shown.id)!)])]])
    }
    /// A link an app in the space previews: its card in web's small type (the row's bottom label small and grey, the
    /// description cut to the lines the card asks for), and under it the app that made it ("By <app>", an App badge).
    @Test func anAppLinkPreviewIsSmallAndSaysWhichAppMadeIt() throws {
        let card = Dynamite_Card.with { $0.sections = [.with { $0.widgets = [
            .with { $0.decoratedText = .with { $0.text = text("owner/repo"); $0.onClick = link("https://example.com/owner/repo"); $0.bottomLabel = text("Updated: today") } },
            .with { $0.textParagraph = .with { $0.text = text("A long description"); $0.maxLines = 2 } },
        ] }] }
        var proto = message(card: card, body: "https://example.com/owner/repo")
        proto.appAttachments[0].app.userID.id = "app1"
        let icon = URL(string: "https://example.com/app.png")!
        let people = ["app1": Person(id: "app1", name: "Example", avatarURL: icon)]
        let shown = try #require(DynamiteMapper.message(proto, in: "dm/d", selfID: "me", people: people))
        let drawn = try #require(shown.attachments.first?.card)
        #expect(drawn.sections == [[
            .row(icon: nil, round: false, label: nil, text: "owner/repo\nUpdated: today", formatting: [TextStyleRange(style: .nowrap, start: 0, length: 10),
                TextStyleRange(style: .small, start: 11, length: 14), TextStyleRange(style: .color(Card.secondaryText), start: 11, length: 14)],
                 open: URL(string: "https://example.com/owner/repo")),
            .text("A long description", [], lines: 2),
        ]])
        #expect(drawn.by == Card.Attribution(name: "Example", icon: icon))
        #expect(try mapped(proto).attachments.first?.card?.by == nil)   // an app not looked up yet: no byline
        #expect(CardLayout.size(drawn, maxWidth: 400).height == CardLayout.size(Card(sections: drawn.sections), maxWidth: 400).height + CardLayout.gap + CardLayout.byline)
        #expect(NativeMessageText.size(of: "Updated", formatting: [TextStyleRange(style: .small, start: 0, length: 7)], width: 300).width
                < NativeMessageText.size(of: "Updated", width: 300).width)
    }
    /// In a wide window a card is as wide as a bubble can be, as web draws an app's card across the message column.
    @Test func aCardIsAsWideAsTheWidestBubble() {
        let card = Card(sections: [[.text("A description long enough to need the room", [], lines: 2)]])
        let row = RowLayoutTests.row("https://example.com") { $0.attachments = [Attachment(name: "Card", kind: .card, card: card)] }
        let layout = RowLayout.make(row, width: 1150, own: false, kind: .space)
        #expect(layout.attachments[0].width == RowLayout.maxBubble)
    }
    /// Web's byline: "By" regular, the app's name bold.
    @Test func theBylineBoldsTheAppName() {
        let line = CardView.bylineText("Example")
        #expect(line.characters.count == "By Example".count)
        #expect(line.runs.count == 2 && line.runs.last.map { String(line[$0.range].characters) } == "Example")
        #expect(line.runs.last?.inlinePresentationIntent == .stronglyEmphasized && line.runs.first?.inlinePresentationIntent == nil)
    }
    /// A row whose text doesn't wrap (wrap_text off) keeps its title on one line, cut with "…", as web does.
    @Test func aRowThatDoesNotWrapKeepsItsTitleOnOneLine() throws {
        func row(wrap: Bool) throws -> [TextStyleRange] {
            let card = Dynamite_Card.with { $0.sections = [.with { $0.widgets = [.with { $0.decoratedText = .with {
                $0.text = text("A pull request title"); $0.bottomLabel = text("Open"); $0.wrapText = wrap } }] }] }
            guard case .row(_, _, _, _, let formatting, _)? = try mapped(message(card: card)).attachments.first?.card?.sections.first?.first else { return [] }
            return formatting
        }
        #expect(try row(wrap: false).contains(TextStyleRange(style: .nowrap, start: 0, length: 20)))
        #expect(try !row(wrap: true).contains { $0.style == .nowrap })
        let long = String(repeating: "A long pull request title ", count: 10)
        #expect(NativeMessageText.size(of: long, formatting: [TextStyleRange(style: .nowrap, start: 0, length: (long as NSString).length)], width: 300).height
                == NativeMessageText.size(of: "A", width: 300).height)
    }
    /// A label's coloured runs ("Open" in green) keep their colour; runs in the default text grey take the label's grey.
    @Test func aLabelKeepsItsColouredRuns() throws {
        func run(_ string: String, light: UInt32, dark: UInt32) -> Dynamite_TextSegment {
            .with { $0.run = .with { $0.text = string; $0.colorPair = .with { $0.light = light; $0.dark = dark } } }
        }
        let card = Dynamite_Card.with { $0.sections = [.with { $0.widgets = [.with { $0.decoratedText = .with {
            $0.text = text("Title"); $0.wrapText = true
            $0.bottomLabel = .with { $0.segments = [run("Open", light: 0x1AA64A, dark: 0x6AF69A), run(" · repo", light: 0x212121, dark: 0xD5D5D5)] } } }] }] }
        guard case .row(_, _, _, let string, let formatting, _)? = try mapped(message(card: card)).attachments.first?.card?.sections.first?.first else { Issue.record("no row"); return }
        #expect(string == "Title\nOpen · repo")
        #expect(formatting.last == TextStyleRange(style: .color(0xFF1AA64A), start: 6, length: 4))   // after the label's grey, so it wins
        #expect(formatting.filter { if case .color = $0.style { true } else { false } }.count == 2)
    }
    /// A paragraph cut to its lines ends in "…" with "Show more" under it; open, it shows all of it and "Show less".
    @Test func aCutParagraphEndsInAnEllipsisAndOpensInPlace() {
        let long = "## What\n\n" + String(repeating: "The storage module then creates no CDN resources. ", count: 8)
        let shown = try? #require(CardLayout.cut(long, [], lines: 2, width: 300))
        #expect(shown?.hasSuffix("…") == true && shown?.hasPrefix("## What") == true)
        #expect(CardLayout.cut("Short", [], lines: 2, width: 300) == nil)
        let card = Card(sections: [[.text(long, [], lines: 2)]])
        let closed = CardLayout.size(card, maxWidth: 300).height, open = CardLayout.size(card, maxWidth: 300, expanded: true).height
        #expect(open > closed && closed > CardLayout.size(Card(sections: [[.text("## What", [])]]), maxWidth: 300).height)
        let row = RowLayoutTests.row("https://example.com") { $0.attachments = [Attachment(name: "Card", kind: .card, card: card)] }
        #expect(RowLayout.make(TimelineRow(message: row.message, begins: true, ends: true, newDay: false, transcriptOpen: true), width: 600, own: false, kind: .space).attachments[0].height
                > RowLayout.make(row, width: 600, own: false, kind: .space).attachments[0].height)
    }
    /// Buttons in columns share one row, as web lays out a Drive comment's: Reply and Resolve at the start, Open at the
    /// end. A button keeps its type: outlined unless it says filled.
    @Test func columnsOfButtonsShareOneRow() throws {
        func button(_ label: String, _ onClick: Dynamite_CardOnClick, type: Int32 = 1) -> Dynamite_CardButton {
            .with { $0.textButton = .with { $0.label = text(label); $0.onClick = onClick; $0.type = type } }
        }
        let act = Dynamite_CardOnClick.with { $0.action = Data([1]) }
        let card = Dynamite_Card.with { $0.sections = [.with { $0.widgets = [.with { $0.columns = .with { $0.columns = [
            .with { $0.horizontalAlignment = 1; $0.widgets = [.with { $0.buttons = [button("Reply", act), button("Resolve", act)] }] },
            .with { $0.horizontalAlignment = 3; $0.widgets = [.with { $0.buttons = [button("Open", link("https://docs.example.com/d/1"), type: 2)] }] },
        ] } }] }] }
        let shown = try mapped(message(card: card))
        let chat = try #require(ChatLink.url(message: shown.id))
        #expect(shown.attachments.first?.card?.sections == [[.links([
            Card.Link(title: "Reply", url: chat), Card.Link(title: "Resolve", url: chat),
            Card.Link(title: "Open", url: URL(string: "https://docs.example.com/d/1")!, trailing: true, filled: true)])]])
    }
    @Test func aMeetCallIsAChipThatOpensTheMeeting() throws {
        let call = Dynamite_Message.with { m in
            m.id.messageID = "m2"; m.id.parentID.topicID.topicID = "m2"; m.creator.userID.id = "u1"
            m.annotations = [.with { a in a.type = .gsuiteIntegration
                a.gsuiteIntegrationMetadata.meetCall = .with { $0.status = .callEnded; $0.meeting.link.url = "https://meet.google.com/abc-defg-hij" } }]
            // The call's own card says the same; Google Chat shows the call, not the card. Google updates the message
            // as the call ends, which is not an edit.
            m.appAttachments = [.with { $0.card.sections = [.with { $0.widgets = [.with { $0.decoratedText.text = text("Call ended", bold: true) }] }] }]
            m.lastEditTime = 1
        }
        let shown = try mapped(call)
        #expect(shown.text.isEmpty && !shown.edited)   // a chip, as Google Chat shows a call
        let chip = try #require(shown.attachments.first)
        #expect(chip.kind == .call && chip.call == .ended && chip.name == "Call ended" && chip.url == URL(string: "https://meet.google.com/abc-defg-hij"))
        #expect(chip.opensInBrowser && chip.detail == "Google Meet")
        #expect(QuotedMessage.summary(text: shown.text, attachments: shown.attachments) == "Call ended")   // Home and notifications
    }
    /// A Meet link carries a VIDEO_CALL annotation: Google Chat shows a card to join under the link.
    @Test func aMeetLinkGetsAJoinChip() throws {
        var link = Dynamite_Message.with { m in
            m.id.messageID = "m3"; m.id.parentID.topicID.topicID = "m3"; m.creator.userID.id = "u1"
            m.textBody = "https://meet.google.com/abc-defg-hij"
        }
        // The annotation as Google Chat sends it: type 11, then field 12 holding {1: {1 name, 2 code, 3 url, 15: {flags}}, 2: false}.
        func ld(_ field: Int, _ bytes: [UInt8]) -> [UInt8] { [UInt8(field << 3 | 2), UInt8(bytes.count)] + bytes }
        let url = Array("https://meet.google.com/abc-defg-hij".utf8)
        let space = ld(1, Array("spaces/abcdefghijklmn".utf8)) + ld(2, Array("abc-defg-hij".utf8)) + ld(3, url) + ld(15, [0x08, 0x01])
        let annotation = [0x08, 0x0B, 0x10, 0x00, 0x18, 0x24] + ld(12, ld(1, space) + [0x10, 0x00])
        var bytes: [UInt8] = try link.serializedBytes()
        bytes += ld(11, annotation)
        link = try Dynamite_Message(serializedBytes: Data(bytes))
        let shown = try mapped(link)
        #expect(shown.text == "https://meet.google.com/abc-defg-hij")
        let chip = try #require(shown.attachments.first)
        #expect(chip.kind == .call && chip.call == .join && chip.name == "Join video meeting" && chip.url == URL(string: "https://meet.google.com/abc-defg-hij"))
    }
    /// A video meeting started from the composer: no text, only the meeting's VIDEO_CALL annotation (start 0, length 0).
    /// Google Chat shows it as a "Join video meeting" card; it is a message, not a system event.
    @Test func aVideoMeetingWithNoTextShowsItsJoinChip() throws {
        let proto = Dynamite_Message.with { m in
            m.id.messageID = "v1"; m.id.parentID.topicID.topicID = "v1"; m.creator.userID.id = "alex"; m.messageType = .userMessage
            m.annotations = [.with { a in
                a.type = .videoCall; a.startIndex = 0; a.length = 0; a.chipRenderType = .render
                a.videoCallMetadata = .with { $0.meetingSpace = .with { $0.url = "https://meet.google.com/abc-defg-hij?hs=122" } }
            }]
        }
        let shown = try mapped(proto)
        #expect(!shown.isSystem && shown.text.isEmpty)
        let chip = try #require(shown.attachments.first)
        #expect(chip.kind == .call && chip.call == .join && chip.name == "Join video meeting" && chip.url?.host() == "meet.google.com")
    }
    /// Google sends a YouTube link with no title or picture and "do not render", and Google Chat shows a card anyway:
    /// "YouTube video" with the video's thumbnail and a play button.
    @Test func aYouTubeLinkGetsAVideoCard() throws {
        for (link, id) in [("https://www.youtube.com/watch?v=abcDEF12345&t=3", "abcDEF12345"), ("https://youtu.be/abcDEF12345", "abcDEF12345")] {
            let message = Dynamite_Message.with { m in
                m.id.messageID = "m4"; m.id.parentID.topicID.topicID = "m4"; m.creator.userID.id = "u1"; m.textBody = "Watch the video below."
                m.annotations = [.with { a in a.type = .url; a.startIndex = 10; a.length = 5
                    a.urlMetadata = .with { $0.url.url = link; $0.domain = "www.youtube.com"; $0.shouldNotRender = true; $0.urlSource = .richText } }]
            }
            let video = try #require(try mapped(message).attachments.first)
            #expect(video.kind == .link && video.name == "YouTube video" && video.domain == "youtube.com" && video.isVideoLink)
            #expect(video.thumbnailURL == URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg") && video.url == URL(string: link))
        }
    }
    /// An app's card can carry the same id as Gemini's feedback row ("accessory_actions"): a reminder's "Manage
    /// reminder" button. It shows, opening the message in Google Chat.
    @Test func anAccessoryCardWithATextButtonIsShown() throws {
        let card = Dynamite_Card.with { $0.sections = [.with { $0.widgets = [.with { $0.buttons = [
            .with { $0.textButton = .with { $0.label = text("Manage reminder"); $0.onClick = .with { $0.action = Data([10, 1, 0x65, 0x40, 1]) } } }] }] }] }   // a dialog, as the reminder's is
        let shown = try mapped(message(card: card, body: "Scheduled reminder", id: "accessory_actions"))
        #expect(shown.attachments.first?.card?.sections == [[.links([Card.Link(title: "Manage reminder", url: ChatLink.url(message: shown.id)!)])]])
    }
    @Test func geminisFeedbackRowIsNotShown() throws {
        let feedback = Dynamite_Card.with { $0.sections = [.with { $0.widgets = [.with { $0.buttons = [.init(), .init()] }] }] }   // icon-only buttons
        let shown = try mapped(message(card: feedback, body: "Here is the answer.", id: "accessory_actions"))
        #expect(shown.text == "Here is the answer." && shown.attachments.isEmpty)
    }
    @Test func aMessageWithNothingToShowSaysSo() throws {
        let shown = try mapped(message(card: Dynamite_Card(), body: ""))
        #expect(shown.text == "Unsupported message")
    }
}

/// Content Parley can't draw yet is never dropped: it shows as "Unsupported message" with a link to it in Google Chat.
/// A system event Parley can't word stays hidden, as web shows none.
struct UnsupportedContentTests {
    private func message(_ configure: (inout Dynamite_Message) -> Void) -> Dynamite_Message {
        .with { m in m.id.messageID = "u1"; m.id.parentID.topicID.topicID = "t1"; m.creator.userID.id = "alex"; m.messageType = .userMessage; configure(&m) }
    }
    private func shown(_ proto: Dynamite_Message) -> Message? { DynamiteMapper.message(proto, in: "space/s", selfID: "me", people: [:]) }

    @Test func aCalendarChipWithNoTextOffersToOpenIt() throws {
        let calendar = message { $0.annotations = [.with { $0.type = .gsuiteIntegration; $0.chipRenderType = .render; $0.gsuiteIntegrationMetadata = .with { _ in } }] }
        let shown = try #require(self.shown(calendar))
        #expect(!shown.isSystem && shown.text == "Unsupported message")
        let open = try #require(shown.attachments.first)
        #expect(open.name == "Open in Google Chat" && open.url?.host() == "chat.google.com" && open.url?.path().hasSuffix("/t1/u1") == true)
    }
    @Test func aCardOfPartsParleyDoesNotDrawOffersToOpenIt() throws {
        let card = message { $0.appAttachments = [.with { $0.card = .with { $0.sections = [.with { $0.widgets = [.with { _ in }] }] }; $0.attachmentID = "c" }] }
        let shown = try #require(self.shown(card))
        #expect(shown.text == "Unsupported message" && shown.attachments.first?.name == "Open in Google Chat")
    }
    @Test func aSystemEventParleyCannotWordStaysHidden() {
        let event = message { $0.messageType = .systemMessage; $0.annotations = [.with { $0.type = .membershipChanged }] }
        #expect(shown(event) == nil)
    }
}
