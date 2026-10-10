import CryptoKit
import Foundation
import UniformTypeIdentifiers
import os

/// Domain IDs: conversation "space/<id>" | "dm/<id>"; message "<conversation>/<topic>/<message>".
enum DynamiteID {
    static func conversation(_ group: Dynamite_GroupId) -> ConversationID? {
        if !group.dmID.dmID.isEmpty { return "dm/\(group.dmID.dmID)" }
        if !group.spaceID.spaceID.isEmpty { return "space/\(group.spaceID.spaceID)" }
        return nil
    }
    static func group(_ id: ConversationID) throws -> Dynamite_GroupId {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else { throw DynamiteError.badID }
        switch parts[0] {
        case "dm": return .with { $0.dmID.dmID = String(parts[1]) }
        case "space": return .with { $0.spaceID.spaceID = String(parts[1]) }
        default: throw DynamiteError.badID
        }
    }
    /// Client-generated Dynamite message id: 8 bytes, base64url, no padding (11 chars), as Google Chat sends.
    /// Derived from the local id so every attempt at one draft sends the same id and Google rejects the repeat.
    static func messageID(for localID: String) -> String {
        Data(SHA256.hash(data: Data(localID.utf8)).prefix(8)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func message(_ conversation: ConversationID, topic: String, message: String) -> MessageID {
        "\(conversation)/\(topic)/\(message)"
    }
    static func protoMessageID(_ id: MessageID) throws -> Dynamite_MessageId {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, !parts[2].isEmpty, !parts[3].isEmpty else { throw DynamiteError.badID }
        let group = try group("\(parts[0])/\(parts[1])")
        return .with {
            $0.parentID.topicID.topicID = String(parts[2])
            $0.parentID.topicID.groupID = group
            $0.messageID = String(parts[3])
        }
    }
    static func topic(of id: MessageID) throws -> String {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, !parts[2].isEmpty else { throw DynamiteError.badID }
        return String(parts[2])
    }
}

enum DynamiteMapper {
    /// Google Chat derives "unread" from read times; there is no per-group count.
    static func unread(_ state: Dynamite_GroupReadState) -> Int {
        if state.unreadMessageCount > 0 { return Int(state.unreadMessageCount) }
        let unread = state.lastHeadMessageCreateTime > state.lastReadTime || state.markAsUnreadTimestamp > 0
        return unread ? max(Int(state.unreadSubscribedTopicCount), 1) : 0
    }
    static func date(_ micros: Int64) -> Date { Date(timeIntervalSince1970: Double(micros) / 1_000_000) }
    /// A custom status as shown: its emoji, then its text; nil when there is neither.
    static func customStatus(_ status: Dynamite_UserStatus) -> String? {
        let text = [status.customStatus.emoji.unicode, status.customStatus.statusText].filter { !$0.isEmpty }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }
    /// Avatar and preview image URLs may be scheme-relative (`//lh3…`). Only https is loaded.
    static func imageURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw.hasPrefix("//") ? "https:" + raw : raw), url.scheme == "https", url.host() != nil else { return nil }
        return url
    }
    static func person(_ user: Dynamite_User) -> Person {
        Person(id: user.userID.id, name: user.name.isEmpty ? "Unknown" : user.name, avatarURL: imageURL(user.avatarURL),
               email: user.email.isEmpty ? nil : user.email)
    }
    /// A directory entry; its member count adds up the joined people (member type 1), as Google Chat counts them.
    static func space(_ entry: Dynamite_SpaceDirectoryEntry) -> SpaceListing? {
        guard let id = DynamiteID.conversation(entry.groupID) else { return nil }
        let people = entry.memberCounts.counts.filter { $0.membershipState == .memberJoined && $0.memberType == 1 }
        return SpaceListing(id: id, name: entry.name.isEmpty ? "Unnamed space" : entry.name,
                            emoji: entry.avatarInfo.emoji.unicode.isEmpty ? nil : entry.avatarInfo.emoji.unicode,
                            avatarURL: imageURL(entry.avatarURL),
                            memberCount: people.isEmpty ? nil : people.reduce(0) { $0 + Int($1.count) },
                            joined: entry.membershipState == .memberJoined)
    }

    static func message(_ proto: Dynamite_Message, in conversation: ConversationID, selfID: String, people: [String: Person]) -> Message? {
        guard !proto.id.messageID.isEmpty else { return nil }
        let senderID = proto.creator.userID.id
        let sender = people[senderID] ?? person(proto.creator)
        let id = DynamiteID.message(conversation, topic: proto.id.parentID.topicID.topicID, message: proto.id.messageID)
        let missing = undrawn(proto, selfID: selfID)
        // Anonymous: the fields only, once per shape; the shape is kept for Help ▸ Export Unsupported Message Shapes.
        if !missing.isEmpty, MessageShapes.shared.withLock({ $0.record(proto, fields: missing, parts: undrawnParts(proto)) }) {
            log.notice("\(MessageShapes.logLine(missing), privacy: .public)")
        }
        // A deleted message Google Chat keeps in its place: who deleted it, in italics, as Google Chat shows it.
        if proto.tombstone.isTombstone {
            let text = switch proto.tombstoneMetadata.type {
            case 2, 6: "Message deleted by a space manager"
            case 3: "Message deleted by an admin"
            case 4: "Message expired"
            default: "Message deleted"
            }
            return Message(id: id, conversationID: conversation, sender: sender, text: text, createdAt: date(proto.createTime),
                           formatting: [TextStyleRange(style: .italic, start: 0, length: (text as NSString).length)])
        }
        guard proto.deleteTime == 0 else { return nil }
        // A system event becomes a service line when we can say what happened; the rest are hidden, as web shows no bubble.
        if isSystem(proto) {
            guard let line = systemText(proto, in: conversation, selfID: selfID, people: people) else { return nil }
            return Message(id: id, conversationID: conversation, sender: sender, text: line, createdAt: date(proto.createTime), isSystem: true)
        }
        let reactions = proto.reactions.compactMap { reaction($0.emoji, count: Int($0.count), mine: $0.currentUserReacted, selfID: selfID) }
        let cards = cards(proto, id: id, people: people)
        // A card shows the file the notice names: no second chip for it, as Google Chat shows none.
        let chips = proto.annotations.compactMap(attachment).filter { cards.isEmpty || !($0.kind == .link && $0.domain == nil) }
        let attachments = chips + proto.annotations.compactMap(call) + cards + appCards(proto, id: id, people: people)
        var quote: QuotedMessage?, fallback: NSRange?
        if proto.hasQuotedMessageMetadata {
            let quoted = proto.quotedMessageMetadata, id = quoted.creator.userID.id, quotedText = richText(quoted.textBody, quoted.annotations)
            // A forward names the conversation it came from, where its id lives; a DM has no name.
            let forwarded = quoted.quoteType == .forward
            let source = forwarded ? DynamiteID.conversation(quoted.group.groupID) ?? conversation : conversation
            // ponytail: quoted authors are not looked up; the name comes from people already resolved or the snapshot. Resolve them if "Unknown" shows up.
            let plain = TextStyleRange.plainWithEmoji(quotedText.text, quotedText.formatting)
            quote = QuotedMessage(sender: people[id]?.name ?? (quoted.creator.name.isEmpty ? "Unknown" : quoted.creator.name),
                                  text: QuotedMessage.summary(text: plain.text, attachments: quoted.annotations.compactMap(attachment)),
                                  id: quoted.messageID.messageID.isEmpty ? nil
                                      : DynamiteID.message(source, topic: quoted.messageID.parentID.topicID.topicID, message: quoted.messageID.messageID),
                                  forwardedFrom: forwarded ? (quoted.group.name.isEmpty ? "a direct message" : quoted.group.name) : nil,
                                  emoji: plain.emoji.isEmpty || plain.text.isEmpty ? nil : plain.emoji)
            // UNVERIFIED: the server may also write a "↪ _Name: …_" line for clients without field 37.
            if proto.textBody.hasPrefix("↪") { fallback = (proto.textBody as NSString).lineRange(for: NSRange(location: 0, length: 0)) }
        }
        let rich = richText(proto.textBody, proto.annotations, hiding: fallback)
        // An app that couldn't answer sends no text, only why: say so, with a link to set it up when it needs that.
        if rich.text.isEmpty, attachments.isEmpty, let response = proto.botResponses.first(where: { $0.type != appSuggestion }) {
            let app = response.bot.name.isEmpty ? sender.name : response.bot.name
            let setup = URL(string: response.setupURL).flatMap { $0.scheme == "https" ? Attachment(name: "Configure \(app)", kind: .link, url: $0) : nil }
            return Message(id: id, conversationID: conversation, sender: sender, text: "\(app) couldn’t respond", createdAt: date(proto.createTime),
                           attachments: setup.map { [$0] } ?? [])
        }
        // Nothing Parley can draw yet: say so and link to it in Google Chat rather than show an empty bubble.
        let unsupported = rich.text.isEmpty && attachments.isEmpty
        let open = ChatLink.url(message: id).map { Attachment(name: "Open in Google Chat", kind: .link, url: $0) }
        var message = Message(id: id, conversationID: conversation, sender: sender,
                       text: unsupported ? "Unsupported message" : rich.text,
                       // Google updates a Meet call's message as the call ends: not an edit anyone made.
                       createdAt: date(proto.createTime), edited: proto.lastEditTime > 0 && !isMeetCall(proto), reactions: reactions, attachments: unsupported ? open.map { [$0] } ?? [] : attachments,
                       formatting: rich.formatting, quote: quote,
                       lastUpdateMicros: [proto.lastUpdateTime, proto.lastEditTime, proto.createTime].first { $0 > 0 },
                       // An app's name, and "Only visible to you" on a message only I can see.
                       via: [appIDs(proto).first.map { people[$0]?.name ?? "App" }, proto.privateMessageViewers.isEmpty ? nil : "Only visible to you"]
                           .compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                       starred: proto.messageLabels.contains { $0.type == .star })
        // Google Chat gives a picture a new token, so a new URL, on every load: its cache knows it by its message and place.
        for index in message.attachments.indices { message.attachments[index].cacheKey = "\(id)#\(index)" }
        message.sources = sources(proto.annotations)
        // "Show thinking": the last activity annotation with steps, as Google Chat shows it.
        message.thinking = proto.annotations.reversed().lazy.compactMap { annotation -> [ThinkingStep]? in
            guard case .activityMetadata(let activity)? = annotation.metadata, !activity.log.entries.isEmpty else { return nil }
            return activity.log.entries.map { ThinkingStep(title: $0.title, text: $0.content) }
        }.first ?? []
        // Google's translation for me, with its own formatting; shown first, the original a click away.
        if proto.hasTranslation, !proto.translation.text.isEmpty {
            let translated = richText(proto.translation.text, proto.translation.annotations)
            message.translation = Translation(text: translated.text, formatting: translated.formatting, from: proto.translation.sourceLanguage)
        }
        return message
    }
    /// A Gemini answer's sources, as Google Chat lists them under "N Sources": those of its zero-length citations, in
    /// order; without any, those its ranged citations name, each once.
    static func sources(_ annotations: [Dynamite_Annotation]) -> [Source] {
        let citations: [(length: Int32, sources: [Dynamite_ContextSource])] = annotations.compactMap { annotation in
            guard case .contextSourceMetadata(let metadata)? = annotation.metadata else { return nil }
            return (annotation.length, metadata.sources)
        }
        // The listed sources are kept as they come, even when two share a link (messages in one space can); only the
        // ranged citations, which repeat sources, are counted once.
        let listed = citations.filter { $0.length == 0 }
        var seen = Set<String>()
        let all: [Dynamite_ContextSource] = listed.isEmpty ? citations.flatMap(\.sources).filter { seen.insert($0.url).inserted } : listed.flatMap(\.sources)
        return all.compactMap { source -> Source? in
            // Some chat sources come over http: kept, and opened over https.
            guard var url = URL(string: source.url), url.scheme == "https" || url.scheme == "http" else { return nil }
            if url.scheme == "http", var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) { parts.scheme = "https"; url = parts.url ?? url }
            let kind: Source.Kind = switch source.kind {
            case .gmail: .gmail
            case .calendar: .calendar
            case .docs: .docs
            case .sheets: .sheets
            case .slides: .slides
            case .drive, .pdf, .video, .audio, .image: .drive
            case .youtube: .youtube
            case .chat: .chat
            case .tasks: .tasks
            default: .web
            }
            return Source(title: source.title.isEmpty ? url.host() ?? source.url : source.title, url: url, kind: kind)
        }
    }
    private static let appSuggestion: Int32 = 6   // BotResponse type APP_SUGGESTION
    private static let log = Logger(subsystem: "dev.cuza.Parley", category: "dynamite")
    /// Field numbers of content on `proto` that Parley doesn't draw ("19.1=<type>" for a bot response), so a new
    /// message shape shows up in the log instead of vanishing: bot responses other than an app suggestion, or the
    /// "couldn't respond" row on a message without text; a private message for someone else; a translation; client-side-
    /// encrypted content. Numbers only: no text or names.
    static func undrawn(_ proto: Dynamite_Message, selfID: String) -> [String] {
        // Drawn: an app suggestion; types 1–4 as the "couldn't respond" row without text, or with text as the card saying
        // what the app needs (`appCards`), when they say it.
        let bots = proto.botResponses.filter { $0.type != appSuggestion
            && !((1...4).contains($0.type) && (proto.textBody.isEmpty || $0.hasRequiredAction)) }
        return bots.map { "19.1=\($0.type)" }
            + (proto.privateMessageViewers.contains { $0.viewer.id != selfID } ? ["35"] : [])
            + (proto.hasEncryptedContent ? ["50"] : [])
            + (undrawnWidgets(proto).isEmpty ? [] : ["15.7.2.2"]) + (droppedButtons(proto).isEmpty ? [] : ["15.7.2.2.8"])
    }
    /// The skeletons (`MessageShapes`) of the card widgets and buttons `undrawn` reports: what tells one gap from another.
    static func undrawnParts(_ proto: Dynamite_Message) -> [String] {
        let widgets = undrawnWidgets(proto).compactMap { try? $0.serializedBytes() as [UInt8] }.compactMap { MessageShapes.skeleton($0[...], path: [15, 7, 2, 2]) }
        let buttons = droppedButtons(proto).compactMap { try? $0.serializedBytes() as [UInt8] }.compactMap { MessageShapes.skeleton($0[...], path: [15, 7, 2, 2, 8]) }
        return widgets + buttons
    }
    /// Card widgets of a kind Parley doesn't draw (an input, a chip list, a grid…).
    private static func undrawnWidgets(_ proto: Dynamite_Message) -> [Dynamite_CardWidget] {
        proto.appAttachments.flatMap { $0.card.sections.flatMap(\.widgets) }.filter { w in
            !(w.hasTextParagraph || !w.buttons.isEmpty || w.hasDecoratedText || w.hasImage || w.hasDivider || w.hasColumns || w.hasTextInput)
        }
    }
    /// Buttons Parley drops: icon-only, or ones that neither open a link nor act (Gemini's feedback row aside).
    private static func droppedButtons(_ proto: Dynamite_Message) -> [Dynamite_CardButton] {
        proto.appAttachments.filter { !isFeedbackRow($0) }.flatMap { $0.card.sections.flatMap(\.widgets) }.flatMap { w in
            w.buttons + w.columns.columns.flatMap { $0.widgets.flatMap(\.buttons) }
        }.filter { !drawn($0) }
    }
    /// An app that could preview a link in my message, offered to me alone, as Google Chat draws it under the message:
    /// "Only visible to you", the app, why, and Install, which opens the message in Google Chat where the install
    /// dialog lives. "Don't install" hides it in Parley only.
    /// Also, on a message with text, an app that needs setting up (types 1–4 with a required action), as Google Chat's
    /// clients word it: "<app> requires authentication" with Sign in, "requires configuration" with Configure (both open
    /// the setup link), or "<app> not responding". The app is named as looked up (`cardAppIDs`), else "App".
    static func appCards(_ proto: Dynamite_Message, id: MessageID, people: [String: Person] = [:]) -> [Attachment] {
        let setups: [Attachment] = proto.textBody.isEmpty ? [] : proto.botResponses.filter { (1...4).contains($0.type) && $0.hasRequiredAction }.map { response -> Attachment in
            let known = people[response.bot.userID.id].flatMap { $0.name == "Unknown" ? nil : $0 }
            let app = response.bot.name.isEmpty ? known?.name ?? "App" : response.bot.name, only = "Only visible to you"
            let icon = URL(string: response.bot.avatarURL).flatMap { $0.scheme == "https" ? $0 : nil } ?? known?.avatarURL
            let (title, button): (String, String?) = switch response.requiredAction {
            case 1: ("\(app) requires configuration", "Configure")
            case 2: ("\(app) requires authentication", "Sign in")
            default: ("\(app) not responding", nil)
            }
            var items: [Card.Item] = [.text(only, [TextStyleRange(style: .color(Card.secondaryText), start: 0, length: (only as NSString).length)]),
                                      .row(icon: icon, round: false, label: nil, text: app, formatting: [TextStyleRange(style: .bold, start: 0, length: (app as NSString).length)]),
                                      .text(title, [])]
            if let button, let url = URL(string: response.setupURL), url.scheme == "https" { items.append(.links([Card.Link(title: button, url: url)])) }
            return Attachment(name: app, kind: .card, card: Card(sections: [items]))
        }
        return suggestions(proto, id: id) + setups
    }
    private static func suggestions(_ proto: Dynamite_Message, id: MessageID) -> [Attachment] {
        proto.botResponses.filter { $0.type == appSuggestion && !$0.bot.name.isEmpty }.map { response in
            let app = response.bot.name, only = "Only visible to you"
            var top: [Card.Item] = [.text(only, [TextStyleRange(style: .color(Card.secondaryText), start: 0, length: (only as NSString).length)]),
                                    .row(icon: URL(string: response.bot.avatarURL).flatMap { $0.scheme == "https" ? $0 : nil }, round: false, label: nil,
                                         text: app, formatting: [TextStyleRange(style: .bold, start: 0, length: (app as NSString).length)]),
                                    // ponytail: always the not-installed wording; Google Chat says "add <app> to this conversation" when I already have the app.
                                    .text("To interactively preview this link, install \(app) and add it to this conversation.", [])]
            if let open = ChatLink.url(message: id) { top.append(.links([Card.Link(title: "Install", url: open)])) }
            return Attachment(name: app, kind: .card, card: Card(sections: [top], dismiss: "Don't install"))
        }
    }
    /// An app's cards, read-only, as attachments drawn under the message: titles and rows, paragraphs with their styles
    /// (a row that opens a link becomes a link), and buttons: one that opens a link opens it, one that sends an action to
    /// the app opens the message in Google Chat (with `id`), where the action works.
    /// Inputs are left out. A Meet call's card says what its chip says, and Ask Gemini's is only its feedback row.
    static func cards(_ proto: Dynamite_Message, id: MessageID? = nil, people: [String: Person] = [:]) -> [Attachment] {
        let chat = id.flatMap(ChatLink.url(message:))
        guard !isMeetCall(proto) else { return [] }
        return proto.appAttachments.compactMap { attachment -> Attachment? in
            guard attachment.hasCard, !isFeedbackRow(attachment) else { return nil }
            var sections: [[Card.Item]] = []
            if attachment.card.hasHeader {
                var title = CardText(); title.add(attachment.card.header.title, bold: true)
                var subtitle = CardText(); subtitle.add(attachment.card.header.subtitle)
                sections.append([title.item, subtitle.item].compactMap { $0 })
            }
            for section in attachment.card.sections {
                var items: [Card.Item] = []
                if !section.header.isEmpty { items.append(.text(section.header, [TextStyleRange(style: .bold, start: 0, length: (section.header as NSString).length)])) }
                for widget in section.widgets {
                    if widget.hasImage, let url = URL(string: widget.image.imageURL), url.scheme == "https" {
                        items.append(.image(url, aspect: widget.image.aspectRatio > 0 ? widget.image.aspectRatio : 16.0 / 9))
                    }
                    if widget.hasDivider { items.append(.divider) }
                    if widget.hasTextInput { items.append(.input(name: widget.textInput.name, label: widget.textInput.label, value: widget.textInput.value)) }
                    items += item(widget.textParagraph) + item(widget.decoratedText) + links(widget.buttons, chat: chat)
                    // Columns of buttons only share one row, the end column's at the end, as web lays them out.
                    let columns = widget.columns.columns
                    if !columns.isEmpty, columns.allSatisfy({ $0.widgets.allSatisfy { !$0.hasTextParagraph && !$0.hasDecoratedText } }) {
                        let row = columns.flatMap { column in
                            links(column.widgets.flatMap(\.buttons), chat: chat).flatMap { item -> [Card.Link] in
                                guard case .links(let links) = item else { return [] }
                                return links.map { var link = $0; if column.horizontalAlignment == 3 { link.trailing = true }; return link }
                            }
                        }
                        if !row.isEmpty { items.append(.links(row)) }
                    } else {
                        for column in columns {
                            for part in column.widgets { items += item(part.textParagraph) + item(part.decoratedText) + links(part.buttons, chat: chat) }
                        }
                    }
                }
                if !items.isEmpty { sections.append(items) }
            }
            guard !sections.isEmpty else { return nil }
            let name = sections.lazy.flatMap { $0 }.compactMap { item -> String? in
                switch item { case .text(let text, _, _), .row(_, _, _, let text, _, _): text; case .links, .image, .divider, .input: nil }
            }.first ?? "Card"
            // The app that made it, once looked up (see `cardAppIDs`).
            let by = people[attachment.app.userID.id].flatMap { $0.name == "Unknown" ? nil : $0 }.map { Card.Attribution(name: $0.name, icon: $0.avatarURL) }
            return Attachment(name: name, kind: .card, card: Card(sections: sections, by: by))
        }
    }
    private static func item(_ widget: Dynamite_TextParagraph) -> [Card.Item] {
        guard widget.hasText else { return [] }
        var text = CardText(); text.add(widget.text)
        guard case .text(let string, let formatting, _)? = text.item else { return [] }
        return [.text(string, formatting, lines: widget.maxLines > 0 ? Int(widget.maxLines) : nil)]
    }
    private static func item(_ widget: Dynamite_DecoratedText) -> [Card.Item] {
        guard widget.hasText || widget.hasTopLabel else { return [] }
        // The row's on-click opens from anywhere on it, its text no link (web draws it plain); links in the text stay.
        var text = CardText(); text.add(widget.text, over: widget.wrapText ? [] : [.nowrap])
        if widget.hasBottomLabel { text.newline(); text.add(widget.bottomLabel, over: [.small, .color(Card.secondaryText)]) }   // small grey print, as web
        var label = CardText(); label.add(widget.topLabel)
        let iconURL = widget.icon.url.isEmpty ? widget.startIconURL : widget.icon.url
        let round = widget.icon.imageType == 2 || widget.startIconImageType == 2
        return [.row(icon: URL(string: iconURL), round: round, label: label.text.isEmpty ? nil : label.text,
                     text: text.trimmed, formatting: text.formatting, open: openLink(widget.onClick))]
    }
    /// Gemini's feedback row: icon buttons only, under the id "accessory_actions". An app's card with that id and a
    /// text button (a reminder's "Manage reminder") is not one.
    private static func isFeedbackRow(_ attachment: Dynamite_AppAttachment) -> Bool {
        attachment.attachmentID == "accessory_actions"
            && !attachment.card.sections.contains { $0.widgets.contains { $0.buttons.contains(where: \.hasTextButton) } }
    }
    /// Whether `links` draws the button: a text button that opens a link or sends an action.
    private static func drawn(_ button: Dynamite_CardButton) -> Bool {
        button.hasTextButton && (button.textButton.onClick.hasOpenLink || button.textButton.onClick.hasAction)
    }
    /// A button that sends an action to the app carries it (Parley sends it with `click_card`), with the message in Google
    /// Chat (`chat`) as its link; one whose action opens a dialog (such as "Sign in") only opens the message there.
    private static func links(_ buttons: [Dynamite_CardButton], chat: URL?) -> [Card.Item] {
        let links = buttons.compactMap { button -> Card.Link? in
            let onClick = button.textButton.onClick
            guard let url = openLink(onClick) ?? (onClick.hasAction ? chat : nil) else { return nil }
            var label = CardText(); label.add(button.textButton.label)
            let filled = [2, 3].contains(button.textButton.type)   // FILLED, FILLED_TONAL
            // An action Parley can send itself, unless it opens a dialog, which only Google Chat draws.
            let sendable = onClick.hasAction && openLink(onClick) == nil && (try? Dynamite_CardAction(serializedBytes: onClick.action)).map { $0.interaction != 1 } == true
            return Card.Link(title: label.text.isEmpty ? "Open" : label.trimmed, url: url, filled: filled ? true : nil, action: sendable ? onClick.action : nil)
        }
        return links.isEmpty ? [] : [.links(links)]
    }
    private struct CardText {
        var text = "", formatting: [TextStyleRange] = []
        var trimmed: String { text.trimmingCharacters(in: .newlines) }
        var item: Card.Item? { trimmed.isEmpty ? nil : .text(trimmed, formatting.filter { $0.start + $0.length <= (trimmed as NSString).length }) }
        var length: Int { (text as NSString).length }
        mutating func newline() { if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" } }
        mutating func add(_ string: String, bold: Bool = false, link: URL? = nil, styles: [TextStyleRange.Style] = []) {
            guard !string.isEmpty else { return }
            let start = length, count = (string as NSString).length
            text += string
            for style in styles + (bold ? [.bold] : []) + (link.map { [.link($0)] } ?? []) { formatting.append(TextStyleRange(style: style, start: start, length: count)) }
        }
        /// Card text from its runs; the HTML with tags stripped when there are none.
        mutating func add(_ formatted: Dynamite_FormattedText, bold: Bool = false, link: URL? = nil, over: [TextRunStyle] = []) {
            let start = length
            var colours: [TextStyleRange] = []
            if formatted.segments.isEmpty {
                add(DynamiteMapper.strippingTags(formatted.html), bold: bold)
            }
            for segment in formatted.segments {
                if segment.hasLink {
                    let target = segment.link.originalHref.isEmpty ? segment.link.href : segment.link.originalHref
                    add(segment.link.text, bold: bold, link: URL(string: target))
                    continue
                }
                let run = segment.run
                var styles: [TextRunStyle] = []
                for style in run.styles {
                    switch style {
                    case .italic: styles.append(.italic)
                    case .underline: styles.append(.underline)
                    case .strikethrough: styles.append(.strike)
                    case .code, .codeBlock: styles.append(.code)
                    default: break
                    }
                }
                let runStart = length
                add(run.text, bold: bold || run.weight == 2, styles: styles)
                // A coloured run ("Open" in green) keeps its colour; grey runs take the text's own colour.
                // ponytail: the light theme's colour in both themes; use `dark` too if a colour reads badly on dark.
                let light = run.colorPair.light, (r, g, b) = (light >> 16 & 0xFF, light >> 8 & 0xFF, light & 0xFF)
                if run.hasColorPair, !(r == g && g == b), length > runStart {
                    colours.append(TextStyleRange(style: .color(0xFF00_0000 | light), start: runStart, length: length - runStart))
                }
                if run.styles.contains(.br) { text += "\n" }
            }
            if let link, length > start { formatting.append(TextStyleRange(style: .link(link), start: start, length: length - start)) }
            if length > start { formatting += over.map { TextStyleRange(style: $0, start: start, length: length - start) } }
            formatting += colours   // after `over`, so a run's colour wins over the label's grey
        }
        typealias TextRunStyle = TextStyleRange.Style
    }
    /// A Google Meet call, as the chip Google Chat shows: its status, opening the meeting.
    static func call(_ annotation: Dynamite_Annotation) -> Attachment? {
        // A video meeting, started from the composer or pasted as a link: Google Chat shows a card to join it.
        if case .videoCallMetadata(let meeting)? = annotation.metadata, let url = URL(string: meeting.meetingSpace.url) {
            return Attachment(name: "Join video meeting", kind: .call, url: url, call: .join)
        }
        let gsuite = annotation.gsuiteIntegrationMetadata
        // A Calendar event: its title and its link come in either order, so the link is whichever string is one.
        if gsuite.hasCalendar {
            let strings = [gsuite.calendar.event.first, gsuite.calendar.event.second].filter { !$0.isEmpty }
            let link = strings.compactMap { URL(string: $0) }.first { $0.scheme == "https" }
            let title = strings.first { URL(string: $0)?.scheme != "https" } ?? "Event"
            return Attachment(name: title, contentType: Attachment.calendarType, kind: .link, url: link)
        }
        if gsuite.hasTasks {
            return Attachment(name: gsuite.tasks.task.title.isEmpty ? "Task" : gsuite.tasks.task.title, contentType: Attachment.taskType, kind: .link)
        }
        guard gsuite.hasMeetCall else { return nil }
        let call = gsuite.meetCall
        let status: Attachment.CallStatus = switch call.status { case .callStarted: .started; case .callMissed: .missed; default: .ended }
        // Google Chat's wording: a huddle (meeting kind 1) has no "missed", and a missed call is "Call missed".
        let huddle = call.meeting.link.kind == 1
        let name = switch status {
        case .started: huddle ? "Huddle started" : "Call started"
        case .missed: huddle ? "Huddle ended" : "Call missed"
        case .ended, .join: huddle ? "Huddle ended" : "Call ended"
        }
        return Attachment(name: name, kind: .call, url: URL(string: call.meeting.link.url), call: status, huddle: huddle ? true : nil)
    }
    static func isMeetCall(_ proto: Dynamite_Message) -> Bool { proto.annotations.contains { $0.gsuiteIntegrationMetadata.hasMeetCall } }
    /// A card action's link: the original target, else Google's redirect. Nil for actions that need Google Chat.
    static func openLink(_ onClick: Dynamite_CardOnClick) -> URL? {
        guard onClick.hasOpenLink else { return nil }
        return URL(string: onClick.openLink.originalURL.isEmpty ? onClick.openLink.url : onClick.openLink.originalURL)
    }
    static func strippingTags(_ html: String) -> String {
        let breaks = html.replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
        let plain = breaks.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return plain.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
    }
    /// The app that posted a message on its sender's behalf (a bot user id, looked up as a bot).
    /// The apps that made the message's cards, looked up as bots for the card's "By <app>" line.
    static func cardAppIDs(_ proto: Dynamite_Message) -> [String] {
        (proto.appAttachments.map(\.app.userID.id) + proto.botResponses.map(\.bot.userID.id)).filter { !$0.isEmpty }
    }
    static func appIDs(_ proto: Dynamite_Message) -> [String] {
        proto.creator.userID.actingUserID.isEmpty ? [] : [proto.creator.userID.actingUserID]
    }
    /// What a quote reply or a forward sends to name the message: its id and update time, as Google Chat sends it. nil without an id.
    static func quotedRef(_ quote: QuotedMessage) throws -> Dynamite_QuotedMessageRef? {
        guard let id = quote.id else { return nil }
        let messageID = try DynamiteID.protoMessageID(id)
        return .with { $0.messageID = messageID; $0.lastUpdateTime = quote.lastUpdateMicros ?? 0
            $0.quoteType = quote.forwardedFrom == nil ? .quoteReply : .forward }
    }

    /// Annotation kinds that only system events carry.
    private static let systemKinds: Set<Dynamite_Annotation.TypeEnum> = [
        .membershipChanged, .roomUpdated, .groupRetentionSettingsUpdated, .readReceiptsSettingsUpdated,
        .incomingWebhookChanged, .integrationConfigUpdated, .migratedFromLegacyThreadedRoom]
    /// Marked SYSTEM_MESSAGE, carrying a system annotation, or no text with only metadata (membership, history setting, ...).
    static func isSystem(_ proto: Dynamite_Message) -> Bool {
        proto.messageType == .systemMessage
            || proto.annotations.contains { annotation in
                switch annotation.metadata {
                case .membershipChanged, .roomUpdated: true
                default: systemKinds.contains(annotation.type)
                }
            }
            || (proto.textBody.isEmpty && !proto.annotations.isEmpty && proto.annotations.compactMap(attachment).isEmpty && proto.annotations.compactMap(call).isEmpty && cards(proto).isEmpty
                && proto.appAttachments.isEmpty && !proto.annotations.contains { contentKinds.contains($0.type) })
    }
    /// Annotations that are a message's content (a file, a link, a chip…): a message carrying one is never taken for an
    /// empty system event and hidden, even when Parley can't draw it yet.
    private static let contentKinds: Set<Dynamite_Annotation.TypeEnum> = [
        .url, .driveFile, .driveDoc, .driveSheet, .driveSlide, .video, .image, .pdf, .videoCall, .uploadMetadata,
        .gsuiteIntegration, .driveForm, .customEmoji, .consentedAppUnfurl, .group, .email, .contextSource, .notebooklm, .meetingCard]
    /// Everyone a message names: its sender and, in a system event, who acted and who was affected (to look up names).
    static func userIDs(_ proto: Dynamite_Message) -> [String] {
        [proto.creator.userID.id] + proto.annotations.flatMap { annotation -> [String] in
            switch annotation.metadata {
            case .membershipChanged(let change): [change.initiator.id] + change.affectedMembers.map(\.userID.id)
            case .roomUpdated(let update): [update.initiator.userID.id]
            default: []
            }
        }
    }
    /// The service line for a system event, one line per change it describes; nil when it describes none.
    static func systemText(_ proto: Dynamite_Message, in conversation: ConversationID, selfID: String, people: [String: Person]) -> String? {
        let noun = conversation.hasPrefix("space/") ? "space" : "conversation"
        func name(_ id: String, _ snapshot: String = "", first: Bool) -> String {
            if id == selfID { return first ? "You" : "you" }
            return people[id]?.name ?? (snapshot.isEmpty ? (first ? "Someone" : "someone") : snapshot)
        }
        let lines = proto.annotations.compactMap { annotation -> String? in
            switch annotation.metadata {
            case .membershipChanged(let change):
                let snapshots = Dictionary(change.affectedMemberProfiles.map { ($0.user.userID.id, $0.user.name) }, uniquingKeysWith: { a, _ in a })
                let ids = change.affectedMembers.map(\.userID.id).filter { !$0.isEmpty }
                func affected(first: Bool) -> String? {
                    ids.isEmpty ? nil : ListFormatter.localizedString(byJoining: ids.enumerated().map { name($1, snapshots[$1] ?? "", first: first && $0 == 0) })
                }
                let actor = name(change.initiator.id.isEmpty ? proto.creator.userID.id : change.initiator.id, first: true)
                switch change.type {
                case .added, .botAdded: return affected(first: false).map { "\(actor) added \($0)" }
                case .invited: return affected(first: false).map { "\(actor) invited \($0)" }
                case .removed, .botRemoved: return affected(first: false).map { "\(actor) removed \($0)" }
                case .joined: return "\(affected(first: true) ?? actor) joined"
                case .left: return "\(affected(first: true) ?? actor) left"
                default: return nil
                }
            case .roomUpdated(let update):
                let actorID = update.initiator.userID.id.isEmpty ? proto.creator.userID.id : update.initiator.userID.id
                let actor = name(actorID, update.initiator.name, first: true)
                if !update.renameMetadata.newName.isEmpty { return "\(actor) renamed the \(noun) to “\(update.renameMetadata.newName)”" }
                guard update.hasGroupDetailsMetadata else { return nil }
                // As Google Chat words it: a new description is quoted, guidelines are only named; an admin is not named.
                let who = update.initiatorType == 2 ? "An admin" : actor
                let new = update.groupDetailsMetadata.newGroupDetails, prev = update.groupDetailsMetadata.prevGroupDetails
                var changes: [String] = []
                if new.description_p != prev.description_p {
                    changes.append(new.description_p.isEmpty ? "\(who) removed the \(noun) description"
                                   : "\(who) updated the \(noun) description to:\n\(new.description_p)")
                }
                if new.guidelines != prev.guidelines {
                    changes.append("\(who) \(new.guidelines.isEmpty ? "removed" : "updated") the \(noun) guidelines")
                }
                return changes.isEmpty ? nil : changes.joined(separator: "\n")
            default: return nil
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// A pushed BATCH_REACTIONS_UPDATED, applied onto the message's `existing` reactions: it names only the emoji that changed,
    /// each replacing its own reaction (gone at count 0); the others stay as they are.
    static func reactions(_ summaries: [Dynamite_ReactionSummary], onto existing: [Reaction] = [], selfID: String) -> [Reaction] {
        var reactions = existing
        for summary in summaries {
            guard let (text, custom) = reactionKey(summary.emoji) else { continue }
            let changed = reaction(summary.emoji, count: Int(summary.count), mine: summary.currentUserReacted, reactors: summary.reactors.map(\.id), selfID: selfID)
            if let index = reactions.firstIndex(where: { $0.emoji == text && $0.custom?.id == custom?.id }) {
                if let changed { reactions[index] = changed } else { reactions.remove(at: index) }
            } else if let changed { reactions.append(changed) }
        }
        return reactions
    }
    // ponytail: Domain Reaction stores people; the wire gives a count, the own flag and (pushed) the reactors it lists.
    // Filler IDs keep the count. Use real reactors everywhere when reaction details are fetched.
    /// A reaction's emoji as Parley keys it: its text (`:shortcode:` for a custom emoji) and the custom emoji, if any.
    static func reactionKey(_ emoji: Dynamite_Emoji) -> (text: String, custom: CustomEmoji?)? {
        let custom = if case .customEmoji(let proto) = emoji.content { customEmoji(proto) } else { CustomEmoji?.none }
        let text = custom?.text ?? emoji.unicode
        return text.isEmpty ? nil : (text, custom)
    }
    private static func reaction(_ emoji: Dynamite_Emoji, count: Int, mine: Bool, reactors: [String] = [], selfID: String) -> Reaction? {
        guard let (text, custom) = reactionKey(emoji), count > 0 else { return nil }
        var people = Set(reactors.filter { !$0.isEmpty })
        if mine { people.insert(selfID) }
        while people.count < count { people.insert("reactor-\(people.count)") }
        return Reaction(emoji: text, people: people, custom: custom)
    }

    /// A custom emoji as Google Chat sends it; the whole message is kept as `payload` for sending back.
    static func customEmoji(_ proto: Dynamite_CustomEmoji) -> CustomEmoji? {
        guard !proto.uuid.isEmpty || !proto.shortcode.isEmpty else { return nil }
        var image: URL?
        // Encoded strictly: URLComponents leaves "+" and "/" as they are, and a server reads "+" in a query as a space.
        if proto.state != .deleted, let token = proto.readToken.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))), !token.isEmpty {
            image = URL(string: "https://chat.google.com/api/get_custom_emoji_image?custom_emoji_read_token=\(token)&rwa=true")
        }
        let shortcode = proto.shortcode.trimmingCharacters(in: CharacterSet(charactersIn: ":"))   // stored with its colons or without
        return CustomEmoji(id: proto.uuid, shortcode: shortcode.isEmpty ? "emoji" : shortcode, imageURL: image,
                           deleted: proto.state == .deleted, payload: (try? proto.serializedData()) ?? Data())
    }
    /// The `Emoji` a reaction request names: a custom emoji exactly as the server sent it, else the unicode text.
    static func emoji(_ text: String, custom: CustomEmoji?) -> Dynamite_Emoji {
        guard let custom else { return .with { $0.unicode = text } }
        let proto = (try? Dynamite_CustomEmoji(serializedBytes: custom.payload))
            ?? .with { $0.uuid = custom.id; $0.shortcode = custom.shortcode }
        return .with { $0.customEmoji = proto }
    }

    /// Visible text and its styles. HIDDEN ranges (the literal `*`, `_`, `~`, `` ` `` markers) are cut out
    /// and every other range is shifted to match. Offsets are UTF-16 units; ranges past the end are skipped, as Google Chat does.
    static func richText(_ text: String, _ annotations: [Dynamite_Annotation], hiding extra: NSRange? = nil) -> (text: String, formatting: [TextStyleRange]) {
        let count = text.utf16.count
        var hidden = IndexSet(integersIn: Range(extra ?? NSRange()) ?? 0..<0)
        var styles: [(TextStyleRange.Style, NSRange)] = []
        for annotation in annotations {
            let range = NSRange(location: Int(annotation.startIndex), length: Int(annotation.length))
            guard range.location >= 0, range.length > 0, NSMaxRange(range) <= count else { continue }
            switch annotation.metadata {
            case .formatMetadata(let format):
                let style: TextStyleRange.Style
                switch format.formatType {
                case .hidden: hidden.insert(integersIn: range.location..<NSMaxRange(range)); continue
                case .bold: style = .bold
                case .italic: style = .italic
                case .strike: style = .strike
                case .underline: style = .underline
                case .monospace: style = .code
                case .monospaceBlock: style = .codeBlock
                case .bulletedListItem: style = .listItem
                case .heading: style = .heading
                case .quoteBlock: style = .quote
                case .fontColor: style = .color(format.fontColor)
                default: continue
                }
                styles.append((style, range))
            case .userMentionMetadata(let mention):
                let id = mention.type == .mentionAll ? TextStyleRange.everyone : mention.id.id.isEmpty ? nil : mention.id.id
                styles.append((.mention(userID: id), range))
            case .customEmojiMetadata(let metadata):   // one U+FFFD in the text
                if let emoji = customEmoji(metadata.customEmoji) { styles.append((.customEmoji(emoji), range)) }
            case .urlMetadata(let link): if let url = URL(string: link.url.url) { styles.append((.link(url), range)) }
            case .groupMetadata(let chip):   // a space or DM chip: drawn as Google Chat draws it, opening in place
                if let conversation = DynamiteID.conversation(chip.groupID) { styles.append((.chip(conversation, emoji: chip.avatarInfo.emoji.unicode.nilIfEmpty), range)) }
            default: continue
            }
        }
        func shift(_ offset: Int) -> Int { offset - hidden.count(in: 0..<offset) }
        let formatting = styles.compactMap { style, range -> TextStyleRange? in
            let start = shift(range.location), end = shift(NSMaxRange(range))
            return end > start ? TextStyleRange(style: style, start: start, length: end - start) : nil
        }
        let visible = NSMutableString(string: text)
        for cut in hidden.rangeView.reversed() { visible.deleteCharacters(in: NSRange(cut)) }
        return (visible as String, formatting)
    }

    /// FORMAT_DATA annotations for marker-free text, as Google Chat's composer sends them:
    /// one BULLETED_LIST_ITEM per line, plus one BULLETED_LIST over each run of adjacent items. Mentions become USER_MENTION
    /// annotations, custom emoji CUSTOM_EMOJI ones and links URL ones; mentions without a user are skipped.
    static func annotations(_ formatting: [TextStyleRange]) -> [Dynamite_Annotation] {
        func annotation(_ type: Dynamite_FormatMetadata.FormatType, _ start: Int, _ length: Int) -> Dynamite_Annotation {
            .with { $0.type = .formatData; $0.startIndex = Int32(start); $0.length = Int32(length); $0.formatMetadata.formatType = type }
        }
        var annotations: [Dynamite_Annotation] = [], lists: [(start: Int, end: Int)] = [], chips = false
        for range in formatting where range.length > 0 {
            if case .mention(let id?) = range.style { annotations.append(mention(id, range.start, range.length)); continue }
            if case .customEmoji(let emoji) = range.style { annotations.append(customEmoji(emoji, range.start, range.length)); continue }
            if case .link(let url) = range.style { annotations.append(link(url, range.start, range.length)); continue }
            if case .chip(let room, let emoji, let link) = range.style {
                if let chip = chip(room, emoji: emoji, link: link, range.start, range.length) { annotations.append(chip); chips = true }
                continue
            }
            if case .color(let argb) = range.style {
                var colour = annotation(.fontColor, range.start, range.length)
                colour.formatMetadata.fontColor = argb
                annotations.append(colour); continue
            }
            let type: Dynamite_FormatMetadata.FormatType
            switch range.style {
            case .bold: type = .bold
            case .italic: type = .italic
            case .strike: type = .strike
            case .underline: type = .underline
            case .code: type = .monospace
            case .codeBlock: type = .monospaceBlock
            case .quote: type = .quoteBlock
            case .listItem:
                type = .bulletedListItem
                if let last = lists.last, last.end == range.start { lists[lists.count - 1].end = range.start + range.length }
                else { lists.append((range.start, range.start + range.length)) }
            case .heading, .mention, .link, .customEmoji, .color, .chip, .small, .nowrap: continue
            }
            annotations.append(annotation(type, range.start, range.length))
        }
        // A message with a space chip says so, as Google Chat's composer does: clients without group smart chips (6) then
        // show it as they can, and web Chat draws the chip only with it.
        let features = Dynamite_Annotation.with { a in
            a.type = .requiredMessageFeaturesMetadata; a.chipRenderType = .render; a.requiredMessageFeaturesMetadata.requiredFeatures = [6]
        }
        return annotations + lists.map { annotation(.bulletedList, $0.start, $0.end - $0.start) } + (chips ? [features] : [])
    }
    /// A space or DM chip as Google Chat's composer sends one made from a pasted link: drawn inline (no chip card), opening
    /// the link, with the space's emoji and, for a message's link, that message.
    static func chip(_ room: ConversationID, emoji: String?, link: URL?, _ start: Int, _ length: Int) -> Dynamite_Annotation? {
        guard let group = try? DynamiteID.group(room) else { return nil }
        return .with { a in
            a.type = .group; a.startIndex = Int32(start); a.length = Int32(length)
            a.chipRenderType = .doNotRender; a.inlineRenderFormat = 1
            a.interactionData.url.url = (link ?? ChatLink.url(room)).absoluteString
            a.groupMetadata.groupID = group
            if let emoji { a.groupMetadata.avatarInfo.emoji.unicode = emoji }
            if let chat = link.flatMap(ChatLink.init), let topic = chat.topic,
               let id = try? DynamiteID.protoMessageID("\(room)/\(topic)/\(chat.message ?? topic)") { a.groupMetadata.messageID = id }
        }
    }

    /// A link with its own text, as Google Chat's composer sends one: a RICH_TEXT URL annotation over the text.
    static func link(_ url: URL, _ start: Int, _ length: Int) -> Dynamite_Annotation {
        .with { a in
            a.type = .url; a.startIndex = Int32(start); a.length = Int32(length); a.chipRenderType = .render
            a.urlMetadata = .with { $0.url.url = url.absoluteString; $0.urlSource = .richText; $0.shouldNotRender = false }
        }
    }
    /// A mention as Google Chat's composer builds it: the user id with type HUMAN, mention
    /// type MENTION, and the same id again as invitee info; @all is MENTION_ALL with no user. The range covers the `@Name` text.
    static func mention(_ userID: String, _ start: Int, _ length: Int) -> Dynamite_Annotation {
        let user = Dynamite_UserId.with { $0.id = userID; $0.type = .human }
        return .with { a in
            a.type = .userMention
            a.startIndex = Int32(start); a.length = Int32(length)
            a.userMentionMetadata = userID == TextStyleRange.everyone ? .with { $0.type = .mentionAll }
                : .with { $0.id = user; $0.type = .mention; $0.inviteeInfo.userID = user }
        }
    }

    /// A custom emoji over its U+FFFD, carrying the emoji exactly as the server sent it.
    static func customEmoji(_ emoji: CustomEmoji, _ start: Int, _ length: Int) -> Dynamite_Annotation {
        .with { a in
            a.type = .customEmoji
            a.startIndex = Int32(start); a.length = Int32(length)
            a.customEmojiMetadata.customEmoji = DynamiteMapper.emoji(emoji.text, custom: emoji).customEmoji
        }
    }

    /// An uploaded file as Google Chat sends it: the server's own UploadMetadata,
    /// unchanged (its bytes are the attachment's `uploadToken`), in an UPLOAD_METADATA chip outside the text.
    static func uploadAnnotation(_ upload: Attachment) -> Dynamite_Annotation? {
        guard let token = upload.uploadToken, let bytes = Data(base64Encoded: token),
              let metadata = try? Dynamite_UploadMetadata(serializedBytes: bytes), !metadata.attachmentToken.isEmpty else { return nil }
        return .with { a in
            a.type = .uploadMetadata
            a.chipRenderType = .render
            a.uploadMetadata = metadata
            if let voice = upload.voice {   // the recorder's length and levels, which the server keeps for players to draw
                a.uploadMetadata.voiceMessageMetadata = .with {
                    let nanos = Int64((voice.duration * 1e9).rounded())
                    if nanos >= 1_000_000_000 { $0.duration.seconds = nanos / 1_000_000_000 }
                    if nanos % 1_000_000_000 != 0 { $0.duration.nanos = Int32(nanos % 1_000_000_000) }
                    $0.waveform = voice.waveform.map(Int32.init)
                }
            }
        }
    }

    /// A shared item from `list_attachments`: every link counts, also those a message shows only in its text.
    static func sharedAttachment(_ annotation: Dynamite_Annotation) -> Attachment? {
        if let attachment = attachment(annotation) { return attachment }
        guard case .urlMetadata(let link) = annotation.metadata, let url = URL(string: link.url.url),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        return Attachment(name: [link.title, link.domain, url.host() ?? ""].first { !$0.isEmpty } ?? url.absoluteString, kind: .link, url: url)
    }
    /// Uploads, Drive files and link previews; mentions and formatting are not attachments.
    static func attachment(_ annotation: Dynamite_Annotation) -> Attachment? {
        func size(_ w: Int32, _ h: Int32) -> (Int?, Int?) { w > 0 && h > 0 ? (Int(w), Int(h)) : (nil, nil) }
        switch annotation.metadata {
        case .uploadMetadata(let upload):
            guard !upload.attachmentToken.isEmpty else { return nil }
            let type = upload.contentType, (w, h) = size(upload.originalDimension.width, upload.originalDimension.height)
            let voice = self.voice(upload)
            let kind: Attachment.Kind = voice != nil ? .voice : type.hasPrefix("image/") ? .image : type.hasPrefix("video/") ? .video : .file
            let token = upload.attachmentToken.removingPercentEncoding ?? upload.attachmentToken
            let download = attachmentURL([("url_type", "DOWNLOAD_URL"), ("content_type", type), ("attachment_token", token)])
            return Attachment(name: upload.contentName.isEmpty ? "Attachment" : upload.contentName, contentType: type, kind: kind,
                              // A resized FIFE rendition of a GIF is a still frame: show the animated original.
                              thumbnailURL: kind == .file || kind == .voice ? nil : type == "image/gif" ? download : attachmentURL([("url_type", "FIFE_URL"), ("sz", "w640"), ("content_type", type), ("rwa", "true"), ("attachment_token", token), ("allow_caching", "true")]),
                              url: download,
                              width: w, height: h, voice: voice)
        case .driveMetadata(let drive):
            // "Do not render": the file's title is linked in the text, and Google Chat draws nothing more for it.
            guard annotation.chipRenderType != .doNotRender else { return nil }
            let (w, h) = size(drive.thumbnailWidth, drive.thumbnailHeight)
            // Otherwise a card, as web draws it, with the file's preview rendition: Drive serves it for the file id over the
            // session's cookies, with or without a size (the card's picture fails for a file the viewer can't open).
            let preview = drive.thumbnailURL.isEmpty && !drive.id.isEmpty
                ? drive.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).flatMap { URL(string: "https://lh3.google.com/mail-doc-preview/\($0)?authuser=0&auditContext=thumbnail") }
                : URL(string: drive.thumbnailURL)
            let url = URL(string: annotation.interactionData.url.url)
            // Google Chat may send only the file's id: the kind of file stands in for its title.
            let kind = switch annotation.type {
            case .driveDoc: "Google Doc"
            case .driveSheet: "Google Sheet"
            case .driveSlide: "Google Slides"
            case .driveForm: "Google Form"
            default: Attachment.untitledDrive
            }
            return Attachment(name: drive.title.isEmpty ? kind : drive.title, contentType: drive.mimetype, kind: .link,
                              thumbnailURL: preview, url: url, width: w, height: h,
                              domain: preview == nil ? nil : url?.host()?.lowercased() ?? "drive.google.com")   // a preview makes it a card
        case .urlMetadata(let link):
            // A YouTube video: Google Chat shows a card whatever the flags say, from the video's own thumbnail.
            if let url = URL(string: link.url.url), let id = youTubeID(url) {
                return Attachment(name: "YouTube video", kind: .link, thumbnailURL: URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg"),
                                  url: url, width: 320, height: 180, domain: "youtube.com")   // the 16:9 thumbnail, without the 4:3 one's black bars
            }
            // an explicit chip_render_type wins over should_not_render;
            // RICH_TEXT and inline-format links stay inline links in the text with no chip.
            let render = annotation.chipRenderType != .unknown ? annotation.chipRenderType : link.shouldNotRender ? .doNotRender : .render
            guard render != .doNotRender, link.urlSource != .richText, annotation.inlineRenderFormat != 1,
                  let url = URL(string: link.url.url), url.scheme == "https" || url.scheme == "http" else { return nil }
            let (w, h) = size(link.intImageWidth, link.intImageHeight)
            // No MIME type: Google Chat falls back to the URL's extension.
            let type = !link.mimeType.isEmpty ? link.mimeType : UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? ""
            let thumbnail = imageURL(link.imageURL)
            if type.hasPrefix("image/") {
                return Attachment(name: !link.title.isEmpty ? link.title : url.lastPathComponent, contentType: type, kind: .image,
                                  thumbnailURL: thumbnail ?? url, url: url, width: w, height: h)
            }
            guard thumbnail != nil else { return nil }   // Google Chat shows no card, only the link in the text
            let domain = (link.domain.isEmpty ? url.host() ?? "" : link.domain).lowercased()
            return Attachment(name: [link.title, link.snippet, domain].first { !$0.isEmpty } ?? url.absoluteString, contentType: type, kind: .link,
                              thumbnailURL: thumbnail, url: url, width: w, height: h,
                              snippet: link.snippet.isEmpty ? nil : link.snippet, domain: domain)
        default: return nil
        }
    }
    /// A YouTube video's id, from youtube.com/watch?v=, /shorts/ or youtu.be links.
    static func youTubeID(_ url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        let id: String?
        if host == "youtu.be" { id = url.pathComponents.dropFirst().first }
        else if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            id = url.path().hasPrefix("/shorts/") ? url.pathComponents.dropFirst(2).first
                : URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
        } else { id = nil }
        guard let id, id.count == 11, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return id
    }
    /// A voice message: an upload with voice metadata, or an audio recording Google Chat named (one sent before the metadata was set).
    static func voice(_ upload: Dynamite_UploadMetadata) -> Voice? {
        let recording = upload.contentType.hasPrefix("audio/") && upload.contentName.hasPrefix("UserRecording_")
        guard upload.hasVoiceMessageMetadata || recording else { return nil }
        let meta = upload.voiceMessageMetadata, duration = meta.duration
        return Voice(duration: TimeInterval(duration.seconds) + TimeInterval(duration.nanos) / 1e9,
                     waveform: meta.waveform.map { min(100, max(0, Int($0))) },
                     transcript: upload.transcript.isEmpty ? nil : upload.transcript)
    }
    /// Query parameters in Google Chat's order; every value fully escaped (tokens carry `+`, `/`, `=`).
    private static func attachmentURL(_ query: [(String, String)]) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = query.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
        return URL(string: "https://chat.google.com/api/get_attachment_url?" + encoded)
    }

    /// Oldest message is the thread head; the rest are its replies.
    static func topic(_ proto: Dynamite_Topic, in conversation: ConversationID, selfID: String, people: [String: Person]) -> [Message] {
        let all = proto.replies.sorted { $0.createTime < $1.createTime }
            .compactMap { message($0, in: conversation, selfID: selfID, people: people) }
        guard var head = all.first else { return [] }
        // Google Chat: messages = max(summary total + 1, message count, replies held); the page holds only the newest replies.
        let state = proto.topicReadState
        head.replyCount = max(all.count - 1, Int(state.replySummary.totalReplyCount), Int(state.messageCount) - 1)
        head.following = state.topicLabelID.contains { $0.type == .threadFollowed }
        return [head] + all.dropFirst().map { var reply = $0; reply.threadID = head.id; return reply }
    }

    /// A Home thread row from a topic Google Chat sends with the conversation list (its first message and newest reply).
    /// A topic without a reply (a starred message comes back as one) is no thread row.
    static func homeThread(_ proto: Dynamite_Topic, selfID: String, people: [String: Person]) -> HomeThread? {
        guard let conversation = DynamiteID.conversation(proto.id.groupID) else { return nil }
        let messages = topic(proto, in: conversation, selfID: selfID, people: people)
        guard messages.count > 1, let head = messages.first, let latest = messages.last else { return nil }
        let read = proto.topicReadState.lastReadTime
        let unread = proto.replies.contains { $0.createTime > read && $0.creator.userID.id != selfID && $0.deleteTime == 0 }
        return HomeThread(id: head.id, conversationID: conversation, head: head, latest: latest, unread: unread,
                          time: proto.sortTime > 0 ? date(proto.sortTime) : latest.createdAt)
    }

    static func memberIDs(_ item: Dynamite_WorldItemLite) -> [String] {
        Set((item.dmMembers.members + item.nameUsers.users).map(\.id).filter { !$0.isEmpty }).sorted()
    }

    static func conversation(_ item: Dynamite_WorldItemLite, selfID: String, people: [String: Person]) -> Conversation? {
        guard let id = DynamiteID.conversation(item.groupID) else { return nil }
        let members = memberIDs(item).map { people[$0] ?? Person(id: $0, name: "Unknown") }
        let others = members.filter { $0.id != selfID }
        let isDM = !item.groupID.dmID.dmID.isEmpty
        let groupDM = item.attributes.contains { $0.value == "GROUP_DM" }   // stays a group DM when someone names it
        let kind: ConversationKind = isDM ? (others.count <= 1 ? .direct : .group) : (groupDM || item.roomName.isEmpty ? .group : .space)
        let name = !item.roomName.isEmpty ? item.roomName
            : !item.nameUsers.groupName.isEmpty ? item.nameUsers.groupName
            : others.isEmpty ? "Unnamed conversation" : others.map(\.name).sorted().joined(separator: ", ")
        // A space's emoji comes before its image; a 1:1 DM shows the other person's photo.
        return Conversation(id: id, name: name, kind: kind, members: members,
                            unread: unread(item.readState), pinned: item.readState.starred,
                            muted: item.readState.notificationSettings.muteSettings.state == .muted,
                            emoji: item.avatarInfo.emoji.unicode.isEmpty ? nil : item.avatarInfo.emoji.unicode,
                            avatarURL: imageURL(item.avatarURL) ?? (kind == .direct ? others.first?.avatarURL : nil),
                            description: item.groupLite.spaceDetails.description_p.isEmpty ? nil : item.groupLite.spaceDetails.description_p,
                            notificationLevel: item.readState.notificationSettings.hasLevel ? level(item.readState.notificationSettings.level) : nil,
                            app: kind != .direct ? nil : item.groupType == 11 ? .gemini
                                : item.groupType == 2 || item.dmMembers.members.contains { $0.type == .bot } ? .bot : nil,
                            activity: item.sortTimestamp > 0 ? date(item.sortTimestamp) : nil)
    }

    static func level(_ wire: Dynamite_GroupNotificationSettings.Level) -> NotificationLevel {
        switch wire {
        case .notifyAlways: .always
        case .notifyForMainConversationsWithAutofollow: .all
        case .notifyForMainConversations: .main
        case .notifyLessWithNewThreads: .forYouAndNewThreads
        case .notifyLess: .forYou
        case .notifyNever: .off
        }
    }
    static func wire(_ level: NotificationLevel) -> Dynamite_GroupNotificationSettings.Level {
        switch level {
        case .always: .notifyAlways
        case .all: .notifyForMainConversationsWithAutofollow
        case .main: .notifyForMainConversations
        case .forYouAndNewThreads: .notifyLessWithNewThreads
        case .forYou: .notifyLess
        case .off: .notifyNever
        }
    }
}

// Server drafts: Google Chat's unsent messages of type DRAFT.
extension DynamiteMapper {
    /// A draft as Google Chat lists or pushes it; a scheduled message, or one naming no conversation, is none.
    static func draft(_ proto: Dynamite_UnsentMessage) -> ServerDraft? {
        guard proto.type != .scheduled, !proto.id.id.isEmpty, let conversation = DynamiteID.conversation(proto.id.groupID) else { return nil }
        let rich = richText(proto.textBody, proto.annotations), topic = proto.id.topicID
        return ServerDraft(id: proto.id.id, conversationID: conversation,
                           threadID: topic.isEmpty ? nil : DynamiteID.message(conversation, topic: topic, message: topic),
                           text: rich.text, formatting: rich.formatting,
                           updatedAt: time(proto.updateTime) ?? time(proto.createTime) ?? .now)
    }
    static func time(_ timestamp: Dynamite_Timestamp) -> Date? {
        timestamp.seconds > 0 ? Date(timeIntervalSince1970: Double(timestamp.seconds) + Double(timestamp.nanos) / 1e9) : nil
    }
    /// The draft's id as Google Chat names it: the client-chosen id, its conversation, and its thread's topic for a thread draft.
    static func unsentID(_ id: String, conversation: ConversationID, thread: ThreadID?) throws -> Dynamite_UnsentMessageId {
        try .with {
            $0.id = id
            $0.groupID = try DynamiteID.group(conversation)
            if let thread { $0.topicID = try DynamiteID.topic(of: thread) }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
