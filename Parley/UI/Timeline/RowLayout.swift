import AppKit

/// How messages look (Settings ▸ Message style): Telegram's bubbles, or its plain list where everyone is on the left.
enum TimelineStyle: String, CaseIterable, Sendable { case bubbles, plain }

/// Where everything in one timeline row goes at one width: a pure function of the row, computed before any view
/// exists, so `heightOfRow` only reads it and the row view only applies it.
/// Frames are in row coordinates, top-left origin. Content frames lie inside `bubble`; the tail and avatar outside it.
struct RowLayout: Equatable, Sendable {
    var width: CGFloat
    var height: CGFloat = 0
    var dateHeader: CGRect?
    var avatar: CGRect?
    /// The bubble's body. A tail, on the run's last bubble, grows `tailWidth` out of its bottom corner on the sender's side.
    var bubble: CGRect = .zero
    var tail = false
    var name: CGRect?
    var via: CGRect?          // after the name: a grey capsule naming the app that posted for the sender
    var quote: CGRect?        // the tinted block; its bar runs down the block's leading `quoteBar` points
    var quoteSender: CGRect?
    var quoteText: CGRect?
    var text: CGRect?
    var attachments: [CGRect] = []
    var reactions: [CGRect] = []   // one pill per `message.reactions` entry
    var replies: CGRect?
    var sources: CGRect?           // a Gemini answer's "N Sources" line, which pops its sources up
    var translation: CGRect?       // a translated message's "View original (…)" / "Show translation" toggle
    var thinking: CGRect?          // a Gemini answer's "Show thinking" line, above its text
    var time: CGRect = .zero       // also carries "edited" / "Sending…"
    var retry: CGRect?             // under the bubble when the send failed
    var service: CGRect?           // a system event's centered line ("Ana added Ben"); then there is no bubble
    var seen: CGRect?              // "Seen" / "Seen by …" under my message, when readers' receipts end here
    var bare = false               // large emoji: no bubble, and the time on a pill

    static let margin: CGFloat = 14, avatarSize: CGFloat = 28, avatarGap: CGFloat = 6, tailWidth: CGFloat = 6
    static let padX: CGFloat = 11, padY: CGFloat = 6, spacing: CGFloat = 4, timeGap: CGFloat = 8, maxBubble: CGFloat = 500
    static let quoteBar: CGFloat = 3, cornerRadius: CGFloat = 16
    static let serviceInset = NSSize(width: 10, height: 3)
    static let serviceLines = 6   // a longer service line (a space description) is cut; the row's tooltip has all of it
    static let viaInset = NSSize(width: 5, height: 1), viaGap: CGFloat = 6

    /// Sender names show on the first bubble of a run in groups and spaces; avatars sit beside the run's last
    /// incoming bubble there (Telegram shows neither in one-to-one chats).
    /// `.plain` lays every message out as incoming in a space, with the avatar beside the run's first message.
    static func make(_ row: TimelineRow, width: CGFloat, own: Bool, kind: ConversationKind, style: TimelineStyle = .bubbles) -> RowLayout {
        let plain = style == .plain, readersKind = kind
        let own = own && !plain, kind: ConversationKind = plain ? .space : kind
        let message = row.message
        var layout = RowLayout(width: width)
        var y: CGFloat = 0
        if row.newDay {
            let text = measure(dateText(message), width: width)   // a pill over a wallpaper, so it keeps the service inset
            let size = CGSize(width: text.width + 2 * serviceInset.width, height: text.height + 2 * serviceInset.height)
            layout.dateHeader = CGRect(x: ((width - size.width) / 2).rounded(), y: 9, width: size.width, height: size.height)
            y += size.height + 18
        }
        if message.isSystem {   // Telegram's service message: a small centered pill between bubbles
            let size = measure(serviceText(message.text), width: max(40, width - 2 * margin - 2 * serviceInset.width), lines: serviceLines)
            let pill = CGSize(width: size.width + 2 * serviceInset.width, height: size.height + 2 * serviceInset.height)
            layout.service = CGRect(x: ((width - pill.width) / 2).rounded(), y: y + 8, width: pill.width, height: pill.height)
            layout.height = ceil(y + 8 + pill.height + 8)
            return layout
        }
        y += row.begins ? 8 : 1

        let avatars = !own && kind != .direct
        let leading = margin + (avatars ? avatarSize + avatarGap : 0) + tailWidth
        let maxBubble = max(80, min(Self.maxBubble, width - leading - margin - tailWidth - 40))   // 40: a gutter on the far side
        let inner = maxBubble - 2 * padX

        // Content, laid out from the bubble's top-left; `lastLine` is how far a text-like last line reaches, for the time.
        var cy = padY, contentWidth: CGFloat = 0
        var lastLine: (width: CGFloat, bottom: CGFloat)?
        func place(_ size: CGSize) -> CGRect {
            if cy > padY { cy += spacing }
            let rect = CGRect(x: padX, y: cy, width: size.width, height: size.height)
            cy += size.height; contentWidth = max(contentWidth, size.width)
            return rect
        }
        if !own && row.begins && kind != .direct {
            var name = measure(nameText(message.sender.name), width: inner)
            if let via = message.via {   // the name gives way to the badge, which keeps its size
                let text = measure(viaText(via), width: inner / 2)
                let badge = CGSize(width: text.width + 2 * viaInset.width, height: text.height + 2 * viaInset.height)
                name.width = min(name.width, max(0, inner - viaGap - badge.width))
                let line = place(CGSize(width: name.width + viaGap + badge.width, height: max(name.height, badge.height)))
                layout.name = CGRect(x: line.minX, y: line.minY + ((line.height - name.height) / 2).rounded(), width: name.width, height: name.height)
                layout.via = CGRect(x: line.minX + name.width + viaGap, y: line.minY + ((line.height - badge.height) / 2).rounded(),
                                    width: badge.width, height: badge.height)
            } else {
                layout.name = place(name)
            }
            lastLine = nil
        }
        if !message.thinking.isEmpty {
            layout.thinking = place(measure(thinkingText(), width: inner)); lastLine = nil
        }
        if let quote = message.quote {
            let textWidth = inner - quoteBar - 15
            let sender = measure(quoteSenderText(quote), width: textWidth), body = measure(quoteBodyText(quote), width: textWidth, lines: 2)
            let block = place(CGSize(width: min(inner, max(sender.width, body.width) + quoteBar + 15), height: sender.height + body.height + 8))
            layout.quote = block
            layout.quoteSender = CGRect(x: block.minX + quoteBar + 7, y: block.minY + 4, width: sender.width, height: sender.height)
            layout.quoteText = CGRect(x: block.minX + quoteBar + 7, y: block.minY + 4 + sender.height, width: body.width, height: body.height)
            lastLine = nil
        }
        if !message.text.isEmpty {
            let styled = MessageTextStyle.styled(message.text, message.formatting, own: own, jumbo: message.jumboEmoji)
            var measured = MessageTextStyle.measure(styled, width: inner)
            // The text view is only as wide as the widest measured line; a long word broken mid-way (a URL) can break again
            // at that width and take another line, so the text is measured again there.
            // Keeps that width (the view's) and takes the height measured at it.
            let fitted = MessageTextStyle.measure(styled, width: measured.size.width)
            if fitted.size.height > measured.size.height {
                measured = (CGSize(width: measured.size.width, height: fitted.size.height), fitted.lastLine)
            }
            let rect = place(measured.size)
            layout.text = rect
            lastLine = (measured.lastLine, rect.maxY)
        }
        var cards: [(index: Int, size: CGSize)] = []
        for (index, attachment) in message.attachments.enumerated() {
            if attachment.card != nil {   // placed under the bubble, below
                cards.append((index, attachmentSize(attachment, maxWidth: maxBubble, transcriptOpen: row.transcriptOpen))); layout.attachments.append(.zero); continue
            }
            let rect = place(attachmentSize(attachment, maxWidth: inner, transcriptOpen: row.transcriptOpen))
            layout.attachments.append(rect)
            // A voice message's time sits level with its duration, as Telegram's does (room left for the speed toggle).
            lastLine = attachment.kind == .voice && attachment.voice?.transcript == nil ? (VoiceLayout.button + VoiceLayout.gap + 70, rect.maxY) : nil
        }
        if !message.sources.isEmpty {
            let rect = place(measure(sourcesText(message.sources), width: inner))
            layout.sources = rect; lastLine = (rect.width, rect.maxY)
        }
        if !message.reactions.isEmpty {   // pills flow onto further lines when they don't fit
            if cy > padY { cy += spacing }
            var x: CGFloat = 0, lineTop = cy, lineHeight: CGFloat = 0
            for reaction in message.reactions {
                let text = measure(pillText(reaction), width: inner)
                let pill = CGSize(width: text.width + 14, height: text.height + 6)
                if x > 0 && x + pill.width > inner { x = 0; lineTop += lineHeight + spacing; lineHeight = 0 }
                layout.reactions.append(CGRect(x: padX + x, y: lineTop, width: pill.width, height: pill.height))
                x += pill.width + spacing; lineHeight = max(lineHeight, pill.height)
                contentWidth = max(contentWidth, x - spacing)
            }
            cy = lineTop + lineHeight
            lastLine = (x - spacing, cy)
        }
        if message.replyCount > 0 || row.draft {
            let rect = place(measure(repliesText(message.replyCount, draft: row.draft), width: inner))
            layout.replies = rect; lastLine = (rect.width, rect.maxY)
        }
        // The time sits after the last line when it fits there (Telegram's inline date), else on a line of its own.
        let time = measure(timeText(message), width: inner)
        let timeTop: CGFloat
        if let lastLine, lastLine.width + timeGap + time.width <= inner {
            timeTop = lastLine.bottom - time.height
            contentWidth = max(contentWidth, lastLine.width + timeGap + time.width)
        } else {
            timeTop = cy > padY ? cy + 2 : cy
            cy = timeTop + time.height
            contentWidth = max(contentWidth, time.width)
        }
        cy += padY

        let bubbleWidth = contentWidth + 2 * padX
        let bubble = CGRect(x: own ? width - margin - tailWidth - bubbleWidth : leading, y: y, width: bubbleWidth, height: cy)
        layout.bubble = bubble
        layout.tail = row.ends && !plain
        layout.time = CGRect(x: bubble.maxX - padX - time.width, y: bubble.minY + timeTop, width: time.width, height: time.height)
        layout.bare = message.jumboEmoji != nil
        if layout.bare { layout.time = layout.time.insetBy(dx: -serviceInset.width / 2, dy: -serviceInset.height / 2) }   // room for the pill
        let offset = { (rect: CGRect) in rect.offsetBy(dx: bubble.minX, dy: bubble.minY) }
        layout.name = layout.name.map(offset); layout.via = layout.via.map(offset)
        layout.quote = layout.quote.map(offset); layout.quoteSender = layout.quoteSender.map(offset); layout.quoteText = layout.quoteText.map(offset)
        // As wide as the content (wraps the same: every measured line still fits), so code-block backgrounds fill the bubble.
        layout.text = layout.text.map { offset(CGRect(x: $0.minX, y: $0.minY, width: min(contentWidth, inner), height: $0.height)) }
        layout.attachments = layout.attachments.map(offset)
        layout.reactions = layout.reactions.map(offset)
        layout.replies = layout.replies.map(offset)
        layout.sources = layout.sources.map(offset)
        layout.thinking = layout.thinking.map(offset)
        y = bubble.maxY
        // A translated message's toggle sits under the bubble, on the sender's side, as Google Chat draws it.
        if let translation = message.translation {
            let size = measure(translationText(translation, showingOriginal: row.transcriptOpen), width: maxBubble)
            layout.translation = CGRect(x: own ? bubble.maxX - size.width : bubble.minX, y: y + 3, width: size.width, height: size.height)
            y += size.height + 3
        }
        // An app's card stands on its own under the bubble, as Google Chat draws it, on the sender's side.
        for card in cards {
            y += spacing
            layout.attachments[card.index] = CGRect(x: own ? bubble.maxX - card.size.width : bubble.minX, y: y, width: card.size.width, height: card.size.height)
            y += card.size.height
        }
        let bottom = y
        if message.delivery == .failed {
            let size = measure(retryText(), width: maxBubble)
            layout.retry = CGRect(x: own ? bubble.maxX - size.width : bubble.minX, y: y + 3, width: size.width, height: size.height)
            y += size.height + 3
        }
        if !row.seenBy.isEmpty {
            let size = measure(seenText(row.seenBy, kind: readersKind), width: maxBubble)
            layout.seen = CGRect(x: own ? bubble.maxX - size.width : bubble.minX, y: y + 2, width: size.width, height: size.height)
            y += size.height + 2
        }
        if plain && row.begins { layout.avatar = CGRect(x: margin, y: bubble.minY + 2, width: avatarSize, height: avatarSize) }
        else if !plain && avatars && row.ends { layout.avatar = CGRect(x: margin, y: bottom - avatarSize, width: avatarSize, height: avatarSize) }
        layout.height = ceil(y + 1)
        return layout
    }

    /// `AttachmentView`'s size for a known attachment: media from its dimensions, cards and chips from their text,
    /// all within `maxWidth` (the bubble's inner width, narrow in the thread pane); media keeps its aspect ratio.
    static func attachmentSize(_ attachment: Attachment, maxWidth: CGFloat = .greatestFiniteMagnitude, transcriptOpen: Bool = false) -> CGSize {
        if attachment.kind == .voice { return VoiceLayout.size(attachment.voice, maxWidth: maxWidth, open: transcriptOpen) }
        if let card = attachment.card { return CardLayout.size(card, maxWidth: maxWidth, expanded: transcriptOpen) }
        if attachment.kind == .image || attachment.kind == .video {
            let size = attachment.mediaSize
            guard size.width > maxWidth else { return size }
            return CGSize(width: maxWidth, height: floor(size.height * maxWidth / size.width))
        }
        if attachment.domain != nil {
            let cardWidth = min(320, maxWidth)
            // ponytail: card text measured with AppKit's text-style fonts; SwiftUI's Text may differ by a point or two.
            let width = cardWidth - 20
            var height = attachment.cardImageHeight + 16
            height += measure(styled(attachment.name, .preferredFont(forTextStyle: .callout).bold), width: width, lines: 2).height
            if let snippet = attachment.snippet, snippet != attachment.name {
                height += 2 + measure(styled(snippet, .preferredFont(forTextStyle: .caption1)), width: width, lines: 2).height
            }
            height += 2 + measure(styled(attachment.domain ?? "", .preferredFont(forTextStyle: .caption2)), width: width, lines: 1).height
            return CGSize(width: cardWidth, height: ceil(height))
        }
        // 10 + 28 icon + 8 + text + 10, at most 280 wide.
        let name = measure(styled(attachment.name, .systemFont(ofSize: NSFont.systemFontSize), oneLine: true), width: .greatestFiniteMagnitude)
        let detail = measure(styled(attachment.detail, .preferredFont(forTextStyle: .caption1), oneLine: true), width: .greatestFiniteMagnitude)
        return CGSize(width: min(280, maxWidth, 46 + max(name.width, detail.width) + 10), height: max(28, name.height + 1 + detail.height) + 14)
    }

    // MARK: Label text, shared by the layout (measuring) and the row view (drawing with `TextLabel`)

    static func dateText(_ message: Message, color: NSColor = .secondaryLabelColor) -> NSAttributedString {
        styled(message.createdAt.formatted(date: .abbreviated, time: .omitted), .systemFont(ofSize: 11, weight: .medium), color, oneLine: true)
    }
    static func nameText(_ name: String, color: NSColor = .labelColor) -> NSAttributedString {
        styled(name, .systemFont(ofSize: 13, weight: .semibold), color, oneLine: true)
    }
    static func viaText(_ app: String, color: NSColor = .secondaryLabelColor) -> NSAttributedString {
        styled(app, .systemFont(ofSize: 10, weight: .medium), color, oneLine: true)
    }
    static func quoteSenderText(_ quote: QuotedMessage, color: NSColor = .labelColor) -> NSAttributedString {
        styled(quote.forwardedFrom.map { "↪ \(quote.sender) · from \($0)" } ?? quote.sender, .systemFont(ofSize: 12, weight: .semibold), color, oneLine: true)
    }
    /// The quoted text, its custom emoji drawn as pictures (as the pills draw theirs).
    static func quoteBodyText(_ quote: QuotedMessage, color: NSColor = .secondaryLabelColor) -> NSAttributedString {
        let text = styled(quote.text, .systemFont(ofSize: 13), color)
        guard let emoji = quote.emoji, !emoji.isEmpty else { return text }
        let body = NSMutableAttributedString(attributedString: text)
        for range in emoji.sorted(by: { $0.start > $1.start }) where range.start + range.length <= body.length {
            guard case .customEmoji(let custom) = range.style else { continue }
            let at = NSRange(location: range.start, length: range.length)
            body.replaceCharacters(in: at, with: MessageTextStyle.customEmoji(custom, attributes: body.attributes(at: at.location, effectiveRange: nil)))
        }
        return body
    }
    static func timeText(_ message: Message, color: NSColor = .secondaryLabelColor) -> NSAttributedString {
        let time = message.delivery == .pending ? "Sending…" : message.createdAt.formatted(date: .omitted, time: .shortened)
        return styled((message.starred ? "★ " : "") + (message.edited ? "edited " : "") + time, .systemFont(ofSize: 11), color, oneLine: true)
    }
    static func pillText(_ reaction: Reaction, color: NSColor = .labelColor) -> NSAttributedString {
        let text = styled("\(reaction.custom == nil ? reaction.emoji : "\u{FFFD}") \(reaction.people.count)", .systemFont(ofSize: 12), color, oneLine: true)
        guard let custom = reaction.custom else { return text }
        let pill = NSMutableAttributedString(attributedString: text)
        pill.replaceCharacters(in: NSRange(location: 0, length: 1), with: MessageTextStyle.customEmoji(custom, attributes: text.attributes(at: 0, effectiveRange: nil)))
        return pill
    }
    /// "2 replies", with " · 1 draft" when the thread's reply box holds a draft, as Google Chat shows it.
    static func repliesText(_ count: Int, draft: Bool = false, color: NSColor = .controlAccentColor) -> NSAttributedString {
        let parts = [count == 0 ? nil : count == 1 ? "1 reply" : "\(count) replies", draft ? "1 draft" : nil].compactMap { $0 }
        return styled(parts.joined(separator: " · "), .systemFont(ofSize: 12, weight: .medium), color, oneLine: true)
    }
    /// Google Chat's words for the toggle: "View original (Spanish)" over a translation, "Show translation" over the original.
    static func translationLabel(_ translation: Translation, showingOriginal: Bool) -> String {
        if showingOriginal { return "Show translation" }
        guard let language = Locale.current.localizedString(forLanguageCode: translation.from), language != translation.from else { return "View original" }
        return "View original (\(language))"
    }
    /// The toggle in small type after a translate icon, as Google Chat draws it under the bubble.
    static func translationText(_ translation: Translation, showingOriginal: Bool, color: NSColor = .controlAccentColor) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium), text = NSMutableAttributedString()
        if let image = NSImage(systemSymbolName: "translate", accessibilityDescription: "Translated")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium).applying(.init(hierarchicalColor: color))) {
            let icon = NSTextAttachment(); icon.image = image
            icon.bounds = CGRect(x: 0, y: font.descender + 1, width: image.size.width, height: image.size.height)
            text.append(NSAttributedString(attachment: icon)); text.append(NSAttributedString(string: " "))
        }
        text.append(styled(translationLabel(translation, showingOriginal: showingOriginal), font, color, oneLine: true))
        return text
    }
    static func thinkingText(color: NSColor = .controlAccentColor) -> NSAttributedString {
        styled("Show thinking ›", .systemFont(ofSize: 12, weight: .medium), color, oneLine: true)
    }
    /// Up to three of the sources' kinds as icons, then "N Sources", as Google Chat heads the list.
    static func sourcesText(_ sources: [Source], color: NSColor = .controlAccentColor) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let text = NSMutableAttributedString()
        var kinds: [Source.Kind] = []
        for source in sources where !kinds.contains(source.kind) && kinds.count < 3 { kinds.append(source.kind) }
        for kind in kinds {
            let image = NSImage(systemSymbolName: symbol(kind), accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium).applying(.init(paletteColors: [color])))
            let icon = NSTextAttachment(); icon.image = image
            text.append(NSAttributedString(attachment: icon)); text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: sources.count == 1 ? "1 Source" : "\(sources.count) Sources"))
        text.addAttributes([.font: font, .foregroundColor: color], range: NSRange(location: 0, length: text.length))
        return text
    }
    static func symbol(_ kind: Source.Kind) -> String {
        switch kind {
        case .gmail: "envelope.fill"
        case .calendar: "calendar"
        case .docs: "doc.text.fill"
        case .sheets: "tablecells.fill"
        case .slides: "rectangle.on.rectangle.angled.fill"
        case .drive: "folder.fill"
        case .youtube: "play.rectangle.fill"
        case .chat: "bubble.left.fill"
        case .tasks: "checkmark.circle.fill"
        case .web: "globe"
        }
    }
    static func retryText(color: NSColor = .systemRed) -> NSAttributedString {
        styled("Couldn’t send · Retry", .systemFont(ofSize: 11), color, oneLine: true)
    }
    /// A 1:1 DM has one reader: "Seen". Group DMs name them by first name.
    static func seenText(_ names: [String], kind: ConversationKind, color: NSColor = .secondaryLabelColor) -> NSAttributedString {
        let first = names.map { String($0.split(separator: " ").first ?? Substring($0)) }
        return styled(kind == .direct ? "Seen" : "Seen by " + first.joined(separator: ", "), .systemFont(ofSize: 11), color)
    }
    static func serviceText(_ text: String, color: NSColor = .secondaryLabelColor) -> NSAttributedString {
        styled(text, .systemFont(ofSize: 11, weight: .medium), color, alignment: .center)
    }
    static func styled(_ string: String, _ font: NSFont, _ color: NSColor = .labelColor, oneLine: Bool = false,
                       alignment: NSTextAlignment = .natural) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = oneLine ? .byTruncatingTail : .byWordWrapping
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }
    /// Options `TextLabel` draws with; measuring with the same ones keeps both in agreement.
    static let drawing: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]
    /// A label's size wrapped at `width`, at most `lines` lines (0: no limit).
    static func measure(_ text: NSAttributedString, width: CGFloat, lines: Int = 0) -> CGSize {
        let rect = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: drawing)
        var height = ceil(rect.height)
        if lines > 0, text.length > 0, let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            height = min(height, ceil((font.ascender - font.descender + font.leading) * CGFloat(lines)))
        }
        return CGSize(width: min(width, ceil(rect.width)), height: height)
    }
}

private extension NSFont {
    var bold: NSFont { NSFont(descriptor: fontDescriptor.withSymbolicTraits(.bold), size: pointSize) ?? self }
}
