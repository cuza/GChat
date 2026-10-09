import SwiftUI

/// An app's card under its message, read-only, as Google Chat draws it: sections split by lines, rows with an icon
/// (round for a person), a small label and text, and the buttons that open a link.
struct CardView: View {
    let card: Card
    var dismiss: () -> Void = {}
    var expanded = false          // a cut paragraph shows all of it ("Show more")
    var toggle: () -> Void = {}   // Show more / Show less
    /// Sends a button's action with the card's inputs (`ChatStore.clickCard`).
    var click: (Data, [Card.Input]) async -> Void = { _, _ in }
    @State private var typed: [String: String] = [:]   // what's typed in the card's text fields, by name
    @State private var pending: Card.Link?             // a button whose action is on its way
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: CardLayout.gap) {
                box.frame(height: CardLayout.boxHeight(card, width: geometry.size.width, expanded: expanded))
                if let by = card.by { byline(by) }
            }
        }
    }
    /// "By <app>" and an App badge under the card, as Google Chat credits the app that made it.
    private func byline(_ by: Card.Attribution) -> some View {
        HStack(spacing: 6) {
            if let icon = by.icon { CardIcon(url: icon, round: false, size: 16) }
            Text(Self.bylineText(by.name)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text("App").font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 4).background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: CardLayout.byline)
    }
    /// "By" regular and the app's name bold, as web writes it.
    static func bylineText(_ name: String) -> AttributedString {
        var bold = AttributedString(name); bold.inlinePresentationIntent = .stronglyEmphasized
        return AttributedString("By ") + bold
    }
    private var box: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(card.sections.enumerated()), id: \.offset) { index, section in
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: CardLayout.gap) {
                        ForEach(Array(section.enumerated()), id: \.offset) { _, item in
                            // Each item in a slot of the card's current width, leading: never centred, so content
                            // sized for an older, wider card can't push in from the left.
                            itemView(item, width: geometry.size.width - 2 * CardLayout.pad)
                                .frame(width: geometry.size.width - 2 * CardLayout.pad,
                                       height: CardLayout.height(item, width: geometry.size.width, expanded: expanded), alignment: .topLeading)
                        }
                    }
                    .padding(CardLayout.pad)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    @ViewBuilder private func itemView(_ item: Card.Item, width: CGFloat) -> some View {
        switch item {
        case .text(let text, let formatting, let lines):
            if let shown = CardLayout.cut(text, formatting, lines: lines, width: width) {   // cut: "…", and Show more under it
                VStack(alignment: .leading, spacing: CardLayout.gap) {
                    NativeMessageText(text: expanded ? text : shown, formatting: formatting, own: false, lines: expanded ? 0 : lines ?? 0, maxWidth: width)
                    Button(expanded ? "Show less" : "Show more", action: toggle).buttonStyle(.link).frame(height: CardLayout.more)
                }
                .frame(width: width, alignment: .leading)
            } else {
                NativeMessageText(text: text, formatting: formatting, own: false, lines: lines ?? 0, maxWidth: width).frame(width: width, alignment: .leading)
            }
        case .row(let icon, let round, let label, let text, let formatting, let open):
            HStack(alignment: .top, spacing: CardLayout.iconGap) {
                if let icon { CardIcon(url: icon, round: round) }
                VStack(alignment: .leading, spacing: CardLayout.labelGap) {
                    if let label { Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(height: CardLayout.labelHeight) }
                    NativeMessageText(text: text, formatting: formatting, own: false, maxWidth: CardLayout.textWidth(width + 2 * CardLayout.pad, icon: icon != nil))
                        .frame(maxWidth: .infinity, alignment: .leading)   // the proposed width, cut with "…" when it doesn't wrap
                }
            }
            .frame(width: width, alignment: .leading)
            .overlay {   // the row's on-click: anywhere on it opens it
                if let open { Link(destination: open) { Color.clear.contentShape(Rectangle()) }.buttonStyle(.plain).help(open.absoluteString) }
            }
        case .links(let links):
            HStack(spacing: 8) {
                if let title = card.dismiss { Button(title, action: dismiss).buttonStyle(CardButtonStyle(filled: false)) }
                ForEach(links.filter { $0.trailing != true }, id: \.self, content: button)
                Spacer(minLength: 0)
                ForEach(links.filter { $0.trailing == true }, id: \.self, content: button)
            }
            .frame(width: width)
        case .image(let url, _):
            CardImage(url: url).frame(width: width)
        case .divider:
            Divider().frame(width: width)
        case .input(let name, let label, let value):
            TextField(label, text: Binding(get: { typed[name] ?? value }, set: { typed[name] = $0 }))
                .textFieldStyle(.roundedBorder).frame(width: width)
        }
    }
}

extension CardView {
    @ViewBuilder private func button(_ link: Card.Link) -> some View {
        if let action = link.action {   // sent from here: the card's inputs go with it, and the answer replaces the message
            Button {
                let inputs = card.inputs.map { Card.Input(name: $0.name, value: typed[$0.name] ?? $0.value) }
                pending = link
                Task { await click(action, inputs); pending = nil; typed = [:] }
            } label: {
                if pending == link { ProgressView().controlSize(.small) } else { Text(link.title) }
            }
            .buttonStyle(CardButtonStyle(filled: link.filled == true)).disabled(pending != nil)
        } else {
            Link(link.title, destination: link.url).buttonStyle(CardButtonStyle(filled: link.filled == true)).help(link.url.absoluteString)
        }
    }
}
/// A card's button as Google Chat draws it: outlined (a thin grey rounded border, the title in the accent colour, no
/// fill), or filled in the accent colour.
private struct CardButtonStyle: ButtonStyle {
    let filled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(filled ? Color.white : Color.accentColor)
            .padding(.horizontal, 12).frame(height: CardLayout.buttons - 2)
            .background(filled ? Color.accentColor : Color.clear, in: Capsule())
            .overlay { if !filled { Capsule().strokeBorder(Color(nsColor: .separatorColor)) } }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A card row's icon: a file type, an app, or a person's photo (round).
private struct CardIcon: View {
    let url: URL
    let round: Bool
    var size = CardLayout.icon
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() } else { Color.secondary.opacity(0.15) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: round ? size / 2 : 4))
        .task(id: url) { image = await RemoteImage.image(url, px: 64) }
    }
}

/// A card's picture, filling its width at the card's aspect ratio (a placeholder until it loads).
private struct CardImage: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() } else { Color.secondary.opacity(0.15) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) { image = await RemoteImage.image(url, px: 680) }
    }
}

/// Sizes `CardView` draws at, known before any picture loads; `RowLayout` reserves the same.
enum CardLayout {
    static let pad: CGFloat = 10, gap: CGFloat = 6, icon: CGFloat = 24, iconGap: CGFloat = 8
    static let labelHeight: CGFloat = 15, labelGap: CGFloat = 2, buttons: CGFloat = 26
    /// As wide as the row allows (the widest bubble, `RowLayout.maxBubble`), as web spreads a card across the message column.
    static func width(maxWidth: CGFloat) -> CGFloat { min(RowLayout.maxBubble, maxWidth) }
    static func textWidth(_ cardWidth: CGFloat, icon: Bool) -> CGFloat { cardWidth - 2 * pad - (icon ? Self.icon + iconGap : 0) }
    static let more: CGFloat = 18   // a cut paragraph's Show more / Show less
    static func height(_ item: Card.Item, width cardWidth: CGFloat, expanded: Bool = false) -> CGFloat {
        switch item {
        case .text(let text, let formatting, let lines):
            let width = textWidth(cardWidth, icon: false)
            guard let shown = cut(text, formatting, lines: lines, width: width) else {
                return NativeMessageText.size(of: text, formatting: formatting, width: width, lines: lines ?? 0).height
            }
            let body = expanded ? NativeMessageText.size(of: text, formatting: formatting, width: width)
                : NativeMessageText.size(of: shown, formatting: formatting, width: width, lines: lines ?? 0)
            return body.height + gap + more
        case .row(let icon, _, let label, let text, let formatting, _):
            let body = NativeMessageText.size(of: text, formatting: formatting, width: textWidth(cardWidth, icon: icon != nil)).height
            return max(icon == nil ? 0 : Self.icon, (label == nil ? 0 : labelHeight + labelGap) + body)
        case .links: return buttons
        case .image(_, let aspect): return min(240, textWidth(cardWidth, icon: false) / max(0.2, aspect))
        case .divider: return 1
        case .input: return buttons + 2
        }
    }
    /// A paragraph longer than its `lines` at `width`: its first lines ending in "…", as web cuts it (a cut at an empty
    /// line puts "…" there); nil when it fits or has no limit.
    nonisolated static func cut(_ text: String, _ formatting: [TextStyleRange], lines: Int?, width: CGFloat) -> String? {
        guard let lines, lines > 0 else { return nil }
        let storage = NSTextStorage(attributedString: MessageTextStyle.styled(text, formatting, own: false))
        let manager = NSLayoutManager(), container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager); manager.addTextContainer(container); manager.ensureLayout(for: container)
        var count = 0, end = 0
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, glyphs, stop in
            count += 1
            if count == lines { end = NSMaxRange(manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)); stop.pointee = true }
        }
        let all = storage.string as NSString
        guard count == lines, end < all.length else { return nil }
        var kept = all.substring(to: end)
        if kept.hasSuffix("\n") { kept.removeLast() }
        else { while kept.last == " " { kept.removeLast() } }   // "with the…", not "with the …"
        return kept + "…"
    }
    static let byline: CGFloat = 18   // "By <app>" under a card
    static func size(_ card: Card, maxWidth: CGFloat, expanded: Bool = false) -> CGSize {
        let width = width(maxWidth: maxWidth)
        return CGSize(width: width, height: boxHeight(card, width: width, expanded: expanded) + (card.by == nil ? 0 : gap + byline))
    }
    /// The card's own box, without the byline under it.
    static func boxHeight(_ card: Card, width: CGFloat, expanded: Bool = false) -> CGFloat {
        let sections = card.sections.map { items in
            2 * pad + items.map { height($0, width: width, expanded: expanded) }.reduce(0, +) + gap * CGFloat(max(0, items.count - 1))
        }
        return ceil(sections.reduce(0, +) + CGFloat(max(0, sections.count - 1)))   // 1-pt dividers
    }
}
