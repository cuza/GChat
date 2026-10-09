import AppKit
import SwiftUI

/// The `@name` being typed before the caret: an `@` at the start of the text or after whitespace, then up to 40
/// characters on the same line (names have spaces). A space right after the `@` ends it.
/// With `shortcode`, a custom emoji's `:name` instead: a `:` the same way, then at least one character and no spaces.
struct MentionQuery: Equatable {
    var range: NSRange   // the `@` (or `:`) and what follows it, up to the caret
    var text: String
    var shortcode = false
    var chip: Conversation? = nil   // a Chat link to this conversation, offered as its chip

    static func find(in string: String, caret: Int, shortcode: Bool = false) -> MentionQuery? {
        let ns = string as NSString
        guard caret <= ns.length else { return nil }
        var index = caret
        while index > max(0, caret - 41) {
            index -= 1
            let unit = ns.character(at: index)
            if unit == 10 || unit == 13 || shortcode && (unit == 32 || unit == 9) { return nil }
            guard unit == (shortcode ? 58 : 64) else { continue }   // ":" or "@"
            if index > 0, !(Unicode.Scalar(ns.character(at: index - 1)).map(CharacterSet.whitespacesAndNewlines.contains) ?? false) { return nil }
            let text = ns.substring(with: NSRange(location: index + 1, length: caret - index - 1))
            if text.first?.isWhitespace == true || shortcode && text.isEmpty { return nil }
            return MentionQuery(range: NSRange(location: index, length: caret - index), text: text, shortcode: shortcode)
        }
        return nil
    }
    /// A Google Chat link ending at the caret (pasted or typed) to one of `conversations`' spaces, which Google Chat's
    /// composer offers to turn into the space's chip ("Tab to replace with Town Hall"); it makes none for a DM.
    static func chatLink(in string: String, caret: Int, among conversations: [Conversation]) -> MentionQuery? {
        let ns = string as NSString
        guard caret <= ns.length, caret > 0 else { return nil }
        var start = caret
        while start > 0, let scalar = Unicode.Scalar(ns.character(at: start - 1)), !CharacterSet.whitespacesAndNewlines.contains(scalar) { start -= 1 }
        let text = ns.substring(with: NSRange(location: start, length: caret - start))
        guard let url = URL(string: text), let link = ChatLink(url),
              let conversation = conversations.first(where: { $0.kind == .space && link.conversations.contains($0.id) }) else { return nil }
        return MentionQuery(range: NSRange(location: start, length: caret - start), text: text, chip: conversation)
    }
    /// The query nearest the caret: a `:shortcode` typed after an `@` starts a new one.
    static func nearest(in string: String, caret: Int) -> MentionQuery? {
        let found = [find(in: string, caret: caret), find(in: string, caret: caret, shortcode: true)].compactMap { $0 }
        return found.max { $0.range.location < $1.range.location }
    }
    /// Custom emoji whose shortcode contains `query`, ignoring case; those starting with it first, then by shortcode.
    static func filter(_ emoji: [CustomEmoji], by query: String, limit: Int = 8) -> [CustomEmoji] {
        let query = query.lowercased()
        return Array(emoji.filter { $0.shortcode.lowercased().contains(query) }
            .sorted { ($0.shortcode.lowercased().hasPrefix(query) ? 0 : 1, $0.shortcode) < ($1.shortcode.lowercased().hasPrefix(query) ? 0 : 1, $1.shortcode) }
            .prefix(limit))
    }
    /// People whose name, or any word of it onward, starts with `query`, ignoring case and accents; sorted by name.
    static func filter(_ people: [Person], by query: String, limit: Int = 8) -> [Person] {
        func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let query = fold(query)
        return Array(people.filter { person in
            let name = fold(person.name)
            return query.isEmpty || name.split(separator: " ").contains { name[$0.startIndex...].hasPrefix(query) }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.prefix(limit))
    }
}

/// A row of the composer's suggestion list: someone to @-mention, or a custom emoji for a `:shortcode`.
enum Suggestion: Hashable {
    case person(Person), emoji(CustomEmoji), unicode(Emoji), space(Conversation)
    var id: String {
        switch self {
        case .person(let person): "p:" + person.id; case .emoji(let emoji): "e:" + emoji.id; case .unicode(let emoji): "u:" + emoji.character
        case .space(let room): "s:" + room.id
        }
    }
}

/// The suggestion list, in a borderless child window above the `@` (the way WebKit's text completion shows its list).
/// It never becomes key: the composer keeps focus and drives it with ↑ ↓ Return Tab Esc.
@MainActor final class MentionPopup {
    private var panel: NSPanel?

    func show(_ items: [Suggestion], selected: Int, above anchor: NSRect, in parent: NSWindow,
              loadImage: @escaping (Attachment, Bool) async throws -> Data, pick: @escaping (Suggestion) -> Void) {
        let list = MentionList(items: items, selected: selected, loadImage: loadImage, pick: pick)
        let size = NSSize(width: 260, height: CGFloat(items.count) * MentionList.rowHeight + 8)
        let panel = self.panel ?? {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.contentView = ClickThroughHostingView(rootView: list)
            self.panel = panel
            return panel
        }()
        (panel.contentView as? ClickThroughHostingView<MentionList>)?.rootView = list
        panel.setFrame(NSRect(x: anchor.minX - 8, y: anchor.maxY + 4, width: size.width, height: size.height), display: true)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
    }
    func close() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

/// Clicks land on the first try although the panel is never key.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct MentionList: View {
    static let rowHeight: CGFloat = 30
    let items: [Suggestion]
    let selected: Int
    let loadImage: (Attachment, Bool) async throws -> Data
    let pick: (Suggestion) -> Void
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 8) {
                    switch item {
                    case .person(let person):
                        Avatar(name: person.name, size: 22, url: person.avatarURL)
                        Text(person.name).lineLimit(1)
                    case .emoji(let emoji):
                        CustomEmojiImage(emoji: emoji, size: 22, load: loadImage)
                        Text(emoji.text).lineLimit(1)
                    case .unicode(let emoji):
                        Text(emoji.character).font(.system(size: 18)).frame(width: 22, height: 22)
                        Text(":" + emoji.name.replacingOccurrences(of: " ", with: "-") + ":").lineLimit(1)
                    case .space(let room):   // as Google Chat words it: "tab to replace with <space>"
                        Text("⇥").font(.caption.monospaced()).padding(.horizontal, 4).overlay(RoundedRectangle(cornerRadius: 4).stroke(.tertiary))
                        Text("to replace with").foregroundStyle(index == selected ? .white : .secondary).lineLimit(1).fixedSize()
                        if let emoji = room.emoji { Text(emoji).font(.system(size: 16)).frame(width: 20, height: 20) }
                        else { Avatar(name: room.name, size: 20, url: room.avatarURL) }
                        Text(room.name).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).frame(height: Self.rowHeight)
                .foregroundStyle(index == selected ? .white : .primary)
                .background(index == selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { pick(item) }
                .accessibilityAddTraits(.isButton).accessibilityLabel(Self.label(item))
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }
    private static func label(_ item: Suggestion) -> String {
        switch item {
        case .person(let person): "Mention \(person.name)"; case .emoji(let emoji): "Insert \(emoji.text)"; case .unicode(let emoji): "Insert \(emoji.character)"
        case .space(let room): "Replace the link with \(room.name)"
        }
    }
}
