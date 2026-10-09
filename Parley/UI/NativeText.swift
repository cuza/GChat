import AppKit
import SwiftUI

/// The message field: rich text whose formatting travels as `TextStyleRange`s beside the plain draft text.
struct NativeComposer: NSViewRepresentable {
    var text: String
    var formatting: [TextStyleRange] = []
    var change: (String, [TextStyleRange]) -> Void
    var send: () -> Void
    var editLast: () -> Void
    var cancel: () -> Void
    var attach: ([URL]) -> Void = { _ in }
    var members: [Person] = []            // who `@` can mention
    var spaces: [Conversation] = []       // what a pasted Chat link can become the chip of
    var needMembers: () -> Void = {}      // asked when a mention starts, to load the full member list
    var customEmoji: [CustomEmoji] = []   // what `:shortcode` suggests
    var needCustomEmoji: () -> Void = {}  // asked when a `:shortcode` starts, to load the organisation's list
    var loadImage: (Attachment, Bool) async throws -> Data = { _, _ in throw CancellationError() }   // custom emoji pictures
    var focus: String? = nil              // the field takes focus each time this changes to a new non-nil value
    var handle: ComposerHandle? = nil     // for controls beside the field that act on it
    var height: (CGFloat) -> Void = { _ in }   // the laid-out text height, whenever it changes
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView { Self.makeScrollView(delegate: context.coordinator) }
    static func makeScrollView(delegate: (any NSTextViewDelegate)?) -> NSScrollView {
        let scroll = NSScrollView()
        let view = ComposerTextView(usingTextLayoutManager: false)   // TextKit 1: list bullets are drawn from the layout manager
        view.delegate = delegate
        view.isRichText = true
        view.usesFontPanel = false
        view.importsGraphics = false
        view.typingAttributes = ComposerTextView.visual([:])
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 8, height: 10)
        view.isAutomaticSpellingCorrectionEnabled = true
        view.isContinuousSpellCheckingEnabled = true
        view.isAutomaticTextReplacementEnabled = true
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.setAccessibilityIdentifier("composer")
        scroll.documentView = view
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true   // legacy scrollers ("Show scroll bars: Always", a mouse) only once the draft overflows
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ComposerTextView else { return }
        handle?.view = view
        if let handle { view.askForLink = { [weak handle] in handle?.askForLink?() } }
        view.loadImage = loadImage
        if view.acceptsReload, view.draftText != text || Set(view.formatting) != Set(formatting) { view.load(text, formatting) }
        view.send = send; view.editLast = editLast; view.cancel = cancel; view.attach = attach
        let report = height
        view.heightChanged = { height in DispatchQueue.main.async { report(height) } }   // never mutates state inside this update
        view.needMembers = needMembers
        view.needCustomEmoji = needCustomEmoji
        if view.mentionPeople != members { view.mentionPeople = members }
        view.chipConversations = spaces
        if view.customEmoji != customEmoji { view.customEmoji = customEmoji }
        if focus != context.coordinator.focus {
            context.coordinator.focus = focus
            if focus != nil { view.window?.makeFirstResponder(view) }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposer
        var focus: String?
        init(_ parent: NativeComposer) { self.parent = parent; focus = parent.focus }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? ComposerTextView { parent.change(view.draftText, view.formatting) }
        }
    }
}
/// The composer's field for the controls beside it: the emoji button's picker inserts into it.
@MainActor final class ComposerHandle {
    weak var view: ComposerTextView?
    /// Shows the link form (⌘K, the bar's link button, Format ▸ Link…).
    var askForLink: (() -> Void)?
    /// The selected text, to start the link form with.
    var selectedText: String { view.map { ($0.string as NSString).substring(with: $0.selectedRange()) } ?? "" }
    /// Puts the form's link in and gives the field back the focus.
    func link(_ url: URL, text: String) {
        guard let view else { return }
        view.link(url, text: text.isEmpty ? nil : text)
        view.window?.makeFirstResponder(view)
    }
    /// Shared with reactions: one most-used list, so the picker opens on the emoji I use anywhere.
    let usage: EmojiUsage
    init(usage: EmojiUsage = EmojiUsage()) { self.usage = usage }
    /// The picker for the emoji button: a pick replaces the selection (typed in, so it takes the typing style and the
    /// formatting after it moves along), is counted, closes the picker and gives the field back the focus.
    /// A custom emoji goes in as its picture.
    // ponytail: custom emoji are not counted, so never in "Frequently Used"; EmojiUsage keys are plain strings.
    func emojiPicker(custom: (() async -> [CustomEmoji])? = nil, loadImage: @escaping (Attachment, Bool) async throws -> Data = { _, _ in throw CancellationError() },
                     close: @escaping () -> Void) -> EmojiPicker {
        EmojiPicker(frequent: usage.top(EmojiPicker.columns), pick: { [weak self] emoji in
            guard let self else { return }
            usage.record(emoji)
            if let view {
                view.insertText(emoji, replacementRange: view.selectedRange())
                view.window?.makeFirstResponder(view)
            }
            close()
        }, close: close, custom: custom, pickCustom: { [weak self] emoji in
            if let view = self?.view {
                view.insertCustomEmoji(emoji, replacing: view.selectedRange())
                view.window?.makeFirstResponder(view)
            }
            close()
        }, loadImage: loadImage)
    }
}
/// Each composer style is a custom attribute and `visual` derives fonts, strikes and indents from them, so the
/// attributes alone define `formatting`. Shortcuts: ⌘B bold, ⌘I italic, ⌘U underline, ⇧⌘X strikethrough, ⇧⌘C code
/// (⌘E is "edit last message"), ⌥⇧⌘C code block, ⇧⌘I quote, ⇧⌘8 bulleted list, ⌘K link (outside the composer ⌘K is
/// Jump to Conversation). The formatting bar and the right-click Format menu send the `format…` actions.
final class ComposerTextView: NSTextView {
    var send: (() -> Void)?
    var heightChanged: ((CGFloat) -> Void)?
    fileprivate var reportedHeight: CGFloat = 0
    override func layout() { super.layout(); reportHeight() }   // the first real width, and every resize
    var editLast: (() -> Void)?
    var cancel: (() -> Void)?
    static let styles: [TextStyleRange.Style] = [.bold, .italic, .underline, .strike, .code, .codeBlock, .quote, .listItem]
    /// Styles that cover whole lines.
    static let lineStyles: [TextStyleRange.Style] = [.codeBlock, .quote, .listItem]
    private static func key(_ style: TextStyleRange.Style) -> NSAttributedString.Key { .init("Parley.composer.\(style)") }
    /// Text colour (an ARGB `UInt32`) and links (a `URL`) carry a value, so they have keys of their own.
    static let colorKey = NSAttributedString.Key("Parley.composer.textColor"), linkKey = NSAttributedString.Key("Parley.composer.link")
    /// False while an input method has unfinished text (an accent being typed, an inline prediction): replacing the text
    /// then would make the composition land in the new text and repeat words. The store's change waits for the next update.
    var acceptsReload: Bool { !hasMarkedText() }
    /// Asks for a link's address (and text, with nothing selected); the composer's owner shows the form, then calls `link`.
    var askForLink: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() { return super.keyDown(with: event) }   // an input method's composition owns Return, Esc and the arrows
        if mentionQuery != nil, !mentionMatches.isEmpty {
            let count = mentionMatches.count
            switch event.keyCode {
            case 125: mentionSelection = (mentionSelection + 1) % count; showMentions(); return             // ↓
            case 126: mentionSelection = (mentionSelection + count - 1) % count; showMentions(); return     // ↑
            case 48: insert(mentionMatches[mentionSelection], replacing: mentionQuery!.range); return   // Tab
            case 36, 76:   // Return, Enter; a link's chip takes Tab only, as on web, so Return still sends
                if mentionQuery?.chip == nil { insert(mentionMatches[mentionSelection], replacing: mentionQuery!.range); return }
            case 53: dismissedMention = mentionQuery?.range.location; updateMention(); return               // Esc
            default: break
            }
        }
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) { send?(); return }
        if event.keyCode == 126 && string.isEmpty { editLast?(); return }
        if event.keyCode == 53 { cancel?(); return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard window?.firstResponder === self, modifiers.contains(.command), !modifiers.contains(.control) else { return super.performKeyEquivalent(with: event) }
        if modifiers == [.command, .shift, .option], event.charactersIgnoringModifiers?.lowercased() == "c" { toggle(.codeBlock); return true }
        guard !modifiers.contains(.option) else { return super.performKeyEquivalent(with: event) }
        let style: TextStyleRange.Style? = switch (modifiers.contains(.shift), event.keyCode == 28 ? "8" : event.charactersIgnoringModifiers?.lowercased()) {
        case (false, "b"): .bold
        case (false, "i") where !string.isEmpty: .italic   // in an empty composer ⌘I opens the conversation info
        case (false, "u"): .underline
        case (true, "x"): .strike
        case (true, "c"): .code
        case (true, "i"): .quote
        case (true, "8"): .listItem   // key code 28 is the 8 key, whatever shift makes of it
        default: nil
        }
        if modifiers == [.command], event.charactersIgnoringModifiers?.lowercased() == "k", let askForLink { askForLink(); return true }
        guard let style else { return super.performKeyEquivalent(with: event) }
        toggle(style)
        return true
    }
    /// Foreign styles never come in: paste and drops take plain text, which picks up the typing attributes.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    /// Files and images pasted or dropped here become attachments instead of text.
    var attach: (([URL]) -> Void)?
    var clipboard = NSPasteboard.general
    /// Screenshot thumbnails, Photos, browsers and our own timeline drag images as file promises rather than files.
    private static let fileTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) }
    override func paste(_ sender: Any?) {
        if let attach, let files = Self.files(on: clipboard) { attach(files) } else { super.paste(sender) }
    }
    /// The text view enables Paste only for the types it reads (plain text), so an image on the clipboard needs saying so here.
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(paste(_:)), attach != nil, Self.hasFiles(on: clipboard) { return true }
        return super.validateMenuItem(item)
    }
    static func hasFiles(on pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.availableType(from: [.string]) == nil && pasteboard.availableType(from: [.png, .tiff]) != nil
    }
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { Self.fileTypes + super.acceptableDragTypes }
    override func dragOperation(for dragInfo: any NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        Self.fileTypes.contains(type) ? .copy : super.dragOperation(for: dragInfo, type: type)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let attach else { return super.performDragOperation(sender) }
        if let files = Self.files(on: sender.draggingPasteboard) { attach(files); return true }
        guard let promises = sender.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
              !promises.isEmpty else { return super.performDragOperation(sender) }
        let folder = FileManager.default.temporaryDirectory.appending(path: "Parley Uploads/\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return false }
        for promise in promises {
            promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { url, error in
                if error == nil { MainActor.assumeIsolated { attach([url]) } }
            }
        }
        return true
    }
    /// Copied or dragged files as they are; image data (screenshots, copied images) saved as a PNG in a temporary folder.
    /// Nil when there are neither, or when there is text and no files: copied text may carry a picture of itself.
    static func files(on pasteboard: NSPasteboard) -> [URL]? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { return urls }
        guard pasteboard.availableType(from: [.string]) == nil,
              let png = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff).flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) })
        else { return nil }
        let folder = FileManager.default.temporaryDirectory.appending(path: "Parley Uploads/\(UUID().uuidString)")
        let file = folder.appending(path: "Pasted image.png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: file)
        } catch { return nil }
        return [file]
    }

    @objc func formatBold(_ sender: Any?) { toggle(.bold) }
    @objc func formatItalic(_ sender: Any?) { toggle(.italic) }
    @objc func formatStrike(_ sender: Any?) { toggle(.strike) }
    @objc func formatCode(_ sender: Any?) { toggle(.code) }
    @objc func formatList(_ sender: Any?) { toggle(.listItem) }
    @objc func formatUnderline(_ sender: Any?) { toggle(.underline) }
    @objc func formatCodeBlock(_ sender: Any?) { toggle(.codeBlock) }
    @objc func formatQuote(_ sender: Any?) { toggle(.quote) }
    @objc func formatLink(_ sender: Any?) { askForLink?() }
    /// A colour menu item's tag is its `TextColor` index; -1 is the default colour.
    @objc func formatColor(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? -1
        color(TextColor.allCases.indices.contains(tag) ? TextColor.allCases[tag] : nil)
    }
    /// Right-click: a Format submenu after Paste, every format with its shortcut, as Telegram's composer offers.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let format = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
        format.submenu = formatMenu()
        let at = menu.items.firstIndex { $0.action == #selector(paste(_:)) }.map { $0 + 1 } ?? 0
        menu.insertItem(format, at: at)
        menu.insertItem(.separator(), at: at)
        return menu
    }
    func formatMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers; item.target = self
            menu.addItem(item)
        }
        item("Bold", #selector(formatBold), "b")
        item("Italic", #selector(formatItalic), "i")
        item("Underline", #selector(formatUnderline), "u")
        item("Strikethrough", #selector(formatStrike), "x", [.command, .shift])
        let colors = NSMenuItem(title: "Text Color", action: nil, keyEquivalent: "")
        colors.submenu = NSMenu(title: "Text Color")
        for (index, color) in [(-1, nil)] + TextColor.allCases.enumerated().map({ ($0.offset, Optional($0.element)) }) {
            let swatch = NSMenuItem(title: color?.name ?? "Default", action: #selector(formatColor), keyEquivalent: "")
            swatch.tag = index; swatch.target = self
            swatch.image = color.map { Self.swatch(NSColor(rgb: $0.argb & 0xFF_FFFF)) } ?? Self.swatch(.textColor)
            colors.submenu?.addItem(swatch)
        }
        menu.addItem(colors)
        menu.addItem(.separator())
        item("Bulleted List", #selector(formatList), "8", [.command, .shift])
        item("Quote", #selector(formatQuote), "i", [.command, .shift])
        item("Link…", #selector(formatLink), "k")
        menu.addItem(.separator())
        item("Code", #selector(formatCode), "c", [.command, .shift])
        item("Code Block", #selector(formatCodeBlock), "c", [.command, .shift, .option])
        menu.addItem(.separator())
        item("Clear Formatting", #selector(formatClear))
        return menu
    }
    static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill(); return true
        }
    }
    /// Takes every style off the selection, as Telegram's Clear Formatting; mentions and custom emoji stay.
    @objc func formatClear(_ sender: Any?) {
        guard let storage = textStorage else { return }
        let range = selectedRange()
        guard range.length > 0, shouldChangeText(in: range, replacementString: nil) else { return }
        for key in Self.styles.map(Self.key) + [Self.colorKey, Self.linkKey] { storage.removeAttribute(key, range: range) }
        Self.restyle(storage, in: range)
        didChangeText()
    }
    /// The colour of the selection's first character, or of what is typed next; nil for the default colour.
    var currentColor: TextColor? {
        let range = selectedRange()
        let value = range.length > 0 && range.location < (textStorage?.length ?? 0)
            ? textStorage?.attribute(Self.colorKey, at: range.location, effectiveRange: nil) : typingAttributes[Self.colorKey]
        return (value as? NSNumber).flatMap { argb in TextColor.allCases.first { $0.argb == argb.uint32Value } }
    }
    /// Colours the selection, or what is typed next; nil is the default colour.
    func color(_ color: TextColor?) { apply(Self.colorKey, color.map { NSNumber(value: $0.argb) }) }
    /// Makes the selection a link; with nothing selected (or new `text`), types `text` (else the address) as the link.
    func link(_ url: URL, text: String?) {
        let range = selectedRange()
        if range.length > 0, text == nil || text == (string as NSString).substring(with: range) { apply(Self.linkKey, url); return }
        let shown = text?.isEmpty == false ? text! : url.absoluteString
        var attributes = typingAttributes
        attributes[Self.linkKey] = url
        guard shouldChangeText(in: range, replacementString: shown) else { return }
        textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: shown, attributes: Self.visual(attributes)))
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (shown as NSString).length, length: 0))
        typingAttributes = Self.visual(typingAttributes.filter { $0.key != Self.linkKey })   // typing on after it isn't the link
    }
    private func apply(_ key: NSAttributedString.Key, _ value: Any?) {
        guard let storage = textStorage else { return }
        let range = selectedRange()
        if range.length > 0, shouldChangeText(in: range, replacementString: nil) {
            if let value { storage.addAttribute(key, value: value, range: range) } else { storage.removeAttribute(key, range: range) }
            Self.restyle(storage, in: range)
            didChangeText()
        }
        var typing = typingAttributes
        typing[key] = value
        typingAttributes = Self.visual(typing)
    }

    /// The styles over the text in UTF-16 ranges; a list item is one whole line, its newline included (as Google Chat sends it).
    var formatting: [TextStyleRange] {
        guard let storage = textStorage else { return [] }
        let string = storage.string as NSString
        var ranges: [TextStyleRange] = []
        for style in Self.styles {
            storage.enumerateAttribute(Self.key(style), in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard value != nil else { return }
                // A code block or quote is one range over its lines, its last newline included unless it ends the message.
                guard style == .listItem else { ranges.append(TextStyleRange(style: style, start: range.location, length: range.length)); return }
                string.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, _, line, _ in
                    ranges.append(TextStyleRange(style: .listItem, start: line.location, length: line.length))
                }
            }
        }
        storage.enumerateAttribute(Self.colorKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let argb = value as? NSNumber { ranges.append(TextStyleRange(style: .color(argb.uint32Value), start: range.location, length: range.length)) }
        }
        storage.enumerateAttribute(Self.linkKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let url = value as? URL { ranges.append(TextStyleRange(style: .link(url), start: range.location, length: range.length)) }
        }
        storage.enumerateAttribute(Self.mentionKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let token = value as? MentionToken { ranges.append(TextStyleRange(style: .mention(userID: token.userID), start: range.location, length: range.length)) }
        }
        storage.enumerateAttribute(Self.chipKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let token = value as? MentionToken { ranges.append(TextStyleRange(style: .chip(token.userID, emoji: token.emoji, link: token.link), start: range.location, length: range.length)) }
        }
        storage.enumerateAttribute(Self.customEmojiKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let emoji = value as? CustomEmoji else { return }   // equal neighbours share a run: one range each
            for i in range.location..<NSMaxRange(range) { ranges.append(TextStyleRange(style: .customEmoji(emoji), start: i, length: 1)) }
        }
        guard hasMarkedText() else { return ranges }
        // Counted in `draftText`, which leaves the marked text out: ranges after it move back, ranges over it shrink.
        let marked = markedRange()
        return ranges.compactMap { range in
            let start = range.start, end = range.start + range.length
            func committed(_ i: Int) -> Int { i <= marked.location ? i : max(marked.location, i - marked.length) }
            let s = committed(start), e = committed(end)
            return e > s ? TextStyleRange(style: range.style, start: s, length: e - s) : nil
        }
    }
    /// The text as a draft holds it: each custom emoji (an attachment here) is the U+FFFD Google Chat sends for it, and
    /// only committed text: an input method's composition or an inline prediction (marked text) is not part of it until
    /// it is committed, or Return would send a half-typed word.
    var draftText: String {
        guard let storage = textStorage else { return string }
        let text = NSMutableString(string: storage.string)
        storage.enumerateAttribute(Self.customEmojiKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { text.replaceCharacters(in: range, with: String(repeating: "\u{FFFD}", count: range.length)) }
        }
        if hasMarkedText(), NSMaxRange(markedRange()) <= text.length { text.deleteCharacters(in: markedRange()) }
        return text as String
    }
    /// Replaces the contents; styles the composer can't edit (headings, mentions with no user…) are dropped.
    func load(_ text: String, _ formatting: [TextStyleRange]) {
        let styled = NSMutableAttributedString(string: text)
        for range in formatting where Self.styles.contains(range.style) && range.start >= 0 && range.length > 0 && range.start + range.length <= styled.length {
            styled.addAttribute(Self.key(range.style), value: true, range: NSRange(location: range.start, length: range.length))
        }
        for range in formatting where range.start >= 0 && range.length > 0 && range.start + range.length <= styled.length {
            let r = NSRange(location: range.start, length: range.length)
            if case .color(let argb) = range.style { styled.addAttribute(Self.colorKey, value: NSNumber(value: argb), range: r) }
            if case .link(let url) = range.style { styled.addAttribute(Self.linkKey, value: url, range: r) }
            if case .chip(let room, let emoji, let link) = range.style {   // an edited message's chip stays a chip
                styled.addAttribute(Self.chipKey, value: MentionToken(userID: room, text: (text as NSString).substring(with: r), emoji: emoji, link: link), range: r)
            }
        }
        for range in formatting where range.start >= 0 && range.length > 0 && range.start + range.length <= styled.length {
            guard case .mention(let id?) = range.style else { continue }
            let r = NSRange(location: range.start, length: range.length)
            styled.addAttribute(Self.mentionKey, value: MentionToken(userID: id, text: (text as NSString).substring(with: r)), range: r)
        }
        for range in formatting.reversed() where range.start >= 0 && range.length == 1 && range.start < styled.length {   // one character each
            guard case .customEmoji(let emoji) = range.style else { continue }
            let r = NSRange(location: range.start, length: 1)
            styled.replaceCharacters(in: r, with: Self.customEmojiToken(emoji, attributes: styled.attributes(at: r.location, effectiveRange: nil)))
        }
        Self.restyle(styled, in: NSRange(location: 0, length: styled.length))
        textStorage?.setAttributedString(styled)
        if text.isEmpty { typingAttributes = Self.visual([:]) }   // a sent or cleared draft starts plain
        updateMention()
        loadCustomEmojiImages()
    }
    /// Toggles `style` over the selection (whole lines for lists), or for what is typed next at a caret.
    /// On or off follows the selection's first character, as TextEdit's toggles do.
    func toggle(_ style: TextStyleRange.Style) {
        guard let storage = textStorage else { return }
        let key = Self.key(style)
        var range = selectedRange()
        if Self.lineStyles.contains(style) { range = (string as NSString).paragraphRange(for: range) }
        let on = range.length > 0 ? storage.attribute(key, at: range.location, effectiveRange: nil) == nil : typingAttributes[key] == nil
        if range.length > 0 {
            guard shouldChangeText(in: range, replacementString: nil) else { return }
            if on { storage.addAttribute(key, value: true, range: range) } else { storage.removeAttribute(key, range: range) }
            Self.restyle(storage, in: range)
            didChangeText()
        }
        var typing = typingAttributes
        typing[key] = on ? true : nil
        typingAttributes = Self.visual(typing)
    }
    /// Display attributes for a run carrying composer style keys.
    static func visual(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var visual = attributes.filter { $0.key.rawValue.hasPrefix("Parley.composer.") }
        func has(_ style: TextStyleRange.Style) -> Bool { visual[key(style)] != nil }
        var font: NSFont = has(.code) || has(.codeBlock) ? .monospacedSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 14)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if has(.bold) { traits.insert(.bold) }
        if has(.italic) { traits.insert(.italic) }
        if !traits.isEmpty {
            font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits)), size: font.pointSize) ?? font
        }
        visual[.font] = font
        visual[.foregroundColor] = NSColor.textColor
        if visual[mentionKey] != nil || visual[chipKey] != nil { visual[.foregroundColor] = NSColor.controlAccentColor }
        if visual[customEmojiKey] != nil { visual[.attachment] = attributes[.attachment] }
        if has(.strike) { visual[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if has(.underline) { visual[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if let argb = visual[colorKey] as? NSNumber { visual[.foregroundColor] = NSColor(rgb: argb.uint32Value & 0xFF_FFFF) }
        if visual[linkKey] != nil { visual[.foregroundColor] = NSColor.linkColor; visual[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if has(.code) || has(.codeBlock) { visual[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.08) }
        if has(.quote) { visual[.foregroundColor] = NSColor.secondaryLabelColor }
        if has(.listItem) || has(.quote) || has(.codeBlock) {
            let indent = NSMutableParagraphStyle(); indent.firstLineHeadIndent = 16; indent.headIndent = 16
            visual[.paragraphStyle] = indent
        }
        return visual
    }
    private static func restyle(_ text: NSMutableAttributedString, in range: NSRange) {
        text.enumerateAttributes(in: range) { attributes, run, _ in text.setAttributes(visual(attributes), range: run) }
    }
    // MARK: Mentions

    /// A picked mention: who, and the `@Name` text it was inserted as. A run whose text no longer matches is plain text again.
    struct MentionToken: Hashable { let userID: String; let text: String; var emoji: String? = nil; var link: URL? = nil }
    static let mentionKey = NSAttributedString.Key("Parley.composer.mention")
    /// A conversation chip: a `MentionToken` whose id is the conversation's.
    static let chipKey = NSAttributedString.Key("Parley.composer.chip")
    /// Conversations a pasted Chat link can become the chip of: the account's.
    var chipConversations: [Conversation] = [] { didSet { if chipConversations != oldValue { updateMention() } } }
    var mentionPeople: [Person] = [] { didSet { updateMention() } }
    var needMembers: (() -> Void)?
    private(set) var mentionQuery: MentionQuery?
    private(set) var mentionMatches: [Suggestion] = []
    private var mentionSelection = 0
    private var dismissedMention: Int?   // where the `@` closed with Esc is; it stays closed until another `@`
    private let mentionPopup = MentionPopup()

    /// Replaces `range` (the `@` query) with an `@Name` token and a space, and puts the caret after them.
    func insertMention(_ person: Person, replacing range: NSRange) {
        guard let storage = textStorage else { return }
        let text = "@" + person.name
        var attributes = typingAttributes
        attributes[Self.mentionKey] = MentionToken(userID: person.id, text: text)
        let token = NSMutableAttributedString(string: text, attributes: Self.visual(attributes))
        token.append(NSAttributedString(string: " ", attributes: typingAttributes))
        guard shouldChangeText(in: range, replacementString: token.string) else { return }
        storage.replaceCharacters(in: range, with: token)
        setSelectedRange(NSRange(location: range.location + token.length, length: 0))
        didChangeText()
    }
    /// Replaces `range` (a Chat link) with the conversation's chip: its name, as Google Chat's composer does.
    func insertChip(_ room: Conversation, replacing range: NSRange) {
        guard let storage = textStorage else { return }
        var attributes = typingAttributes
        // The pasted link goes with the chip, as Google Chat's composer sends it (a message's link keeps its message).
        let link = URL(string: (string as NSString).substring(with: range))
        attributes[Self.chipKey] = MentionToken(userID: room.id, text: room.name, emoji: room.emoji, link: link)
        let token = NSAttributedString(string: room.name, attributes: Self.visual(attributes))
        guard shouldChangeText(in: range, replacementString: token.string) else { return }
        storage.replaceCharacters(in: range, with: token)
        setSelectedRange(NSRange(location: range.location + token.length, length: 0))
        didChangeText()
    }
    /// What is typed next never extends a token.
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { super.typingAttributes }
        set {
            let tokens: Set<NSAttributedString.Key> = [Self.mentionKey, Self.chipKey, Self.customEmojiKey, .attachment]
            super.typingAttributes = newValue.keys.contains(where: tokens.contains) ? Self.visual(newValue.filter { !tokens.contains($0.key) }) : newValue
        }
    }
    /// Backspace or forward delete next to a token removes all of it.
    override func deleteBackward(_ sender: Any?) {
        let caret = selectedRange()
        if caret.length == 0, caret.location > 0, let token = mentionRange(at: caret.location - 1) { setSelectedRange(token) }
        super.deleteBackward(sender)
    }
    override func deleteForward(_ sender: Any?) {
        let caret = selectedRange()
        if caret.length == 0, let token = mentionRange(at: caret.location) { setSelectedRange(token) }
        super.deleteForward(sender)
    }
    private func mentionRange(at index: Int) -> NSRange? {
        guard let storage = textStorage, index < storage.length else { return nil }
        var range = NSRange()
        for key in [Self.mentionKey, Self.chipKey]
        where storage.attribute(key, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)) != nil { return range }
        return nil
    }
    override func didChangeText() {
        defer { reportHeight() }
        if let storage = textStorage {   // a token edited inside, or cut in part, becomes plain text
            for key in [Self.mentionKey, Self.chipKey] {
                var broken: [NSRange] = []
                storage.enumerateAttribute(key, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                    if let token = value as? MentionToken, (storage.string as NSString).substring(with: range) != token.text { broken.append(range) }
                }
                for range in broken {
                    storage.removeAttribute(key, range: range)
                    Self.restyle(storage, in: range)
                }
            }
        }
        super.didChangeText()
        updateMention()
    }
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting { updateMention() }
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { mentionPopup.close() }
        return resigned
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { mentionPopup.close() }
        super.viewWillMove(toWindow: newWindow)
    }
    /// Finds the `@` query at the caret (not one inside a token), filters `mentionPeople`, and shows or hides the list.
    func updateMention() {
        let caret = selectedRange()
        var query = caret.length == 0 ? MentionQuery.nearest(in: string, caret: caret.location) : nil
        if query?.range.location != dismissedMention { dismissedMention = nil }
        if let found = query, dismissedMention != nil || textStorage?.attribute(Self.mentionKey, at: found.range.location, effectiveRange: nil) != nil { query = nil }
        if let query, mentionQuery?.shortcode != query.shortcode { query.shortcode ? needCustomEmoji?() : needMembers?() }
        if query == nil, caret.length == 0, let link = MentionQuery.chatLink(in: string, caret: caret.location, among: chipConversations),
           link.range.location != dismissedMention, textStorage?.attribute(Self.chipKey, at: link.range.location, effectiveRange: nil) == nil {
            query = link
        }
        let matches: [Suggestion] = query.map { query in
            if let room = query.chip { return [.space(room)] }
            return query.shortcode ? Array((MentionQuery.filter(customEmoji, by: query.text).map(Suggestion.emoji) + Self.standardEmoji(query.text)).prefix(8))
                : MentionQuery.filter(mentionPeople, by: query.text).map(Suggestion.person)
        } ?? []
        if query?.text != mentionQuery?.text || matches != mentionMatches { mentionSelection = 0 }
        mentionQuery = query; mentionMatches = matches
        showMentions()
    }
    private func showMentions() {
        guard let query = mentionQuery, !mentionMatches.isEmpty, let window, window.firstResponder === self else { mentionPopup.close(); return }
        let anchor = firstRect(forCharacterRange: NSRange(location: query.range.location, length: 1), actualRange: nil)
        mentionPopup.show(mentionMatches, selected: mentionSelection, above: anchor, in: window, loadImage: loadImage) { [weak self] item in
            guard let self, let query = self.mentionQuery else { return }
            self.insert(item, replacing: query.range)
        }
    }
    func insert(_ suggestion: Suggestion, replacing range: NSRange) {
        switch suggestion {
        case .person(let person): insertMention(person, replacing: range)
        case .emoji(let emoji): insertCustomEmoji(emoji, replacing: range, space: true)
        case .unicode(let emoji): insertText(emoji.character + " ", replacementRange: range)
        case .space(let room): insertChip(room, replacing: range)
        }
    }
    /// Standard emoji for a `:shortcode` of two letters or more (one would catch ":D"), as the picker's search finds
    /// them; "thumbs_up" and "folded-hands" read as words.
    private static func standardEmoji(_ text: String) -> [Suggestion] {
        guard text.count >= 2 else { return [] }
        return EmojiCatalog.search(text.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")).prefix(8).map(Suggestion.unicode)
    }

    // MARK: Custom emoji

    /// On a custom emoji's attachment character: the emoji, which `draftText` and `formatting` turn into U+FFFD and its range.
    static let customEmojiKey = NSAttributedString.Key("Parley.composer.customEmoji")
    var customEmoji: [CustomEmoji] = [] { didSet { updateMention() } }
    var needCustomEmoji: (() -> Void)?
    var loadImage: (Attachment, Bool) async throws -> Data = { _, _ in throw CancellationError() }
    private var imageTask: Task<Void, Never>?

    /// Replaces `range` (the selection, or a `:shortcode` query) with the emoji's picture, and a space after a query.
    func insertCustomEmoji(_ emoji: CustomEmoji, replacing range: NSRange, space: Bool = false) {
        guard let storage = textStorage else { return }
        let token = NSMutableAttributedString(attributedString: Self.customEmojiToken(emoji, attributes: typingAttributes))
        if space { token.append(NSAttributedString(string: " ", attributes: typingAttributes)) }
        guard shouldChangeText(in: range, replacementString: token.string) else { return }
        storage.replaceCharacters(in: range, with: token)
        setSelectedRange(NSRange(location: range.location + token.length, length: 0))
        didChangeText()
        loadCustomEmojiImages()
    }
    /// One attachment character drawn as `MessageTextStyle` draws custom emoji; with no picture (deleted), the U+FFFD itself.
    private static func customEmojiToken(_ emoji: CustomEmoji, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        var attributes = visual(attributes.filter { $0.key != mentionKey })
        attributes[customEmojiKey] = emoji
        let picture = MessageTextStyle.customEmoji(emoji, attributes: attributes)
        return picture.length == 1 ? picture : NSAttributedString(string: "\u{FFFD}", attributes: attributes)
    }
    /// Pictures not in `ImageCache` yet draw as placeholders: fetch them, then redraw.
    private func loadCustomEmojiImages() {
        guard let storage = textStorage else { return }
        var pictures = Set<Attachment>()
        storage.enumerateAttribute(Self.customEmojiKey, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let picture = (value as? CustomEmoji)?.image, ImageCache.cached(picture) == nil { pictures.insert(picture) }
        }
        guard !pictures.isEmpty else { return }
        let load = loadImage
        imageTask?.cancel()
        imageTask = Task { [weak self] in
            for picture in pictures { _ = try? await ImageCache.load(picture, load) }
            guard let self, !Task.isCancelled else { return }
            needsDisplay = true
        }
    }

    /// List bullets sit in each item's indent. They are drawn, not typed, so the sent text stays marker-free.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let storage = textStorage, let manager = layoutManager else { return }
        let string = storage.string as NSString, origin = textContainerOrigin, padding = textContainer?.lineFragmentPadding ?? 0
        let bullet: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor]
        storage.enumerateAttribute(Self.key(.listItem), in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            string.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, _, line, _ in
                let fragment = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: line.location), effectiveRange: nil)
                ("•" as NSString).draw(at: NSPoint(x: origin.x + padding + 3, y: origin.y + fragment.minY), withAttributes: bullet)
            }
        }
    }
}
struct NativeMessageText: NSViewRepresentable {
    let text: String
    var formatting: [TextStyleRange] = []
    var quote: QuotedMessage? = nil
    let own: Bool
    /// 0: all of it. Otherwise that many lines ending in "…", and clicks pass through to the view behind (to expand it).
    var lines = 0
    var maxWidth: CGFloat = 440
    /// Changed when a custom emoji's picture arrives, so the text draws it.
    var redraw = 0
    final class TextView: NSTextView {
        var passesClicks = false
        override func hitTest(_ point: NSPoint) -> NSView? { passesClicks ? nil : super.hitTest(point) }
    }
    func makeNSView(context: Context) -> TextView {
        let view = TextView(usingTextLayoutManager: false)   // TextKit 1, like `size(of:width:)`, so measured and drawn wrapping agree
        view.textContainer?.replaceLayoutManager(MessageLayoutManager())   // quote bars, code backgrounds, rounded pills
        view.isEditable = false; view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        return view
    }
    func updateNSView(_ view: TextView, context: Context) {
        Self.show(text, formatting: formatting, quote: quote, own: own, in: view)
        view.textContainer?.maximumNumberOfLines = lines
        view.textContainer?.lineBreakMode = lines > 0 ? .byTruncatingTail : .byWordWrapping
        view.passesClicks = lines > 0
        view.needsDisplay = true
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TextView, context: Context) -> CGSize? {
        let width = min(proposal.width ?? 440, maxWidth)
        let size = Self.size(of: text, formatting: formatting, quote: quote, width: width, lines: lines)
        // Lay out at the width just measured, not one the text view's frame may still carry from a wider layout: a
        // narrowed card otherwise drew its text past its edge.
        if let container = nsView.textContainer, container.size.width != size.width {
            container.size = NSSize(width: size.width, height: .greatestFiniteMagnitude)
        }
        return size
    }
    /// Restyles only real changes: SwiftUI updates rows often, and a reset clears the reader's selection and redoes link detection.
    static func show(_ text: String, formatting: [TextStyleRange] = [], quote: QuotedMessage? = nil, own: Bool, jumbo: Int? = nil, in view: NSTextView) {
        let key = MessageTextStyle.key(text, formatting, quote, own, jumbo: jumbo)
        guard objc_getAssociatedObject(view, &shownKey) as? String != key else { return }
        view.textStorage?.setAttributedString(MessageTextStyle.styled(text, formatting, quote, own: own, jumbo: jumbo))
        objc_setAssociatedObject(view, &shownKey, key, .OBJC_ASSOCIATION_COPY_NONATOMIC)
    }
    /// Cached per styled content and width: the lazy stack re-measures rows on every scroll pass.
    /// Nonisolated, as `MessageTextStyle` is: card layouts are measured with the rows, off the main actor too.
    nonisolated static func size(of text: String, formatting: [TextStyleRange] = [], quote: QuotedMessage? = nil, width: CGFloat, lines: Int = 0) -> CGSize {
        let key = "\(width)\u{0}\(lines)\u{0}\(MessageTextStyle.key(text, formatting, quote, false))" as NSString
        if let cached = sizes.object(forKey: key) { return cached.sizeValue }
        let used = MessageTextStyle.measure(MessageTextStyle.styled(text, formatting, quote, own: false), width: width, lines: lines).size
        let size = CGSize(width: min(width, max(20, used.width)), height: max(18, used.height))
        sizes.setObject(NSValue(size: size), forKey: key)
        return size
    }
    private static var shownKey: UInt8 = 0
    nonisolated(unsafe) private static let sizes = NSCache<NSString, NSValue>()   // NSCache is thread-safe
}

/// Message text styling and TextKit 1 measurement, shared by `NativeMessageText` and the timeline's `RowLayout`
/// so measured and drawn text agree. Nonisolated: row layouts may be computed off the main actor.
enum MessageTextStyle {
    /// On a mention of one person (not @all): their user id, for the person card a click on it shows.
    static let mentionKey = NSAttributedString.Key("Parley.message.mention")
    private static let customEmojiKey = NSAttributedString.Key("Parley.message.customEmoji")
    /// On a drawn custom emoji: the `CustomEmoji`, for the hover card.
    static let emojiKey = NSAttributedString.Key("Parley.message.emoji")
    /// On a space or DM chip: the conversation's link, opened on click (a chip is a pill, not an underlined link).
    static let chipKey = NSAttributedString.Key("Parley.message.chip")
    static func key(_ text: String, _ formatting: [TextStyleRange], _ quote: QuotedMessage?, _ own: Bool, jumbo: Int? = nil) -> String {
        jumbo.map { "\($0)\u{1}" + key(text, formatting, quote, own) } ?? (formatting.isEmpty && quote == nil ? "\(own)\u{0}\(text)" : "\(own)\u{0}\(text)\u{0}\(formatting)\u{0}\(String(describing: quote))")
    }
    /// Large emoji (`Message.jumboEmoji`): one at 56 pt, two at 48, three at 40, as Telegram steps them down.
    static func jumboFont(_ count: Int) -> NSFont { .systemFont(ofSize: [56, 48, 40][min(max(count, 1), 3) - 1]) }
    /// The used size of `styled` wrapped at `width` (TextKit 1 with no line-fragment padding, like the message text view),
    /// and how far its last line reaches. A last line inside a block (code, quote) reports the full width.
    static func measure(_ styled: NSAttributedString, width: CGFloat, lines: Int = 0) -> (size: CGSize, lastLine: CGFloat) {
        let storage = NSTextStorage(attributedString: styled)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = lines
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).size
        var lastLine: CGFloat = 0   // 0 after a trailing newline: the last line is empty
        if styled.length > 0, manager.extraLineFragmentRect.isEmpty {
            let style = styled.attribute(.paragraphStyle, at: styled.length - 1, effectiveRange: nil) as? NSParagraphStyle
            lastLine = style?.textBlocks.isEmpty == false ? width
                : manager.lineFragmentUsedRect(forGlyphAt: manager.numberOfGlyphs - 1, effectiveRange: nil).maxX
        }
        return (CGSize(width: ceil(used.width), height: ceil(used.height)), ceil(lastLine))
    }
    /// Message text with its `TextStyleRange`s applied (ranges past the end are skipped), list bullets, and the quoted message on top.
    /// Blocks use TextKit 1 `NSTextBlock`s (borders, padding, backgrounds), which both the view and `measure` lay out.
    static func styled(_ text: String, _ formatting: [TextStyleRange] = [], _ quote: QuotedMessage? = nil, own: Bool, jumbo: Int? = nil) -> NSAttributedString {
        let key = key(text, formatting, quote, own, jumbo: jumbo)
        let font = jumbo.map(jumboFont) ?? font
        if let cached = styledCache.object(forKey: key as NSString) { return cached }
        let ink = BubblePalette.ownInk
        let color: NSColor = own ? ink : .labelColor, secondary: NSColor = own ? ink.withAlphaComponent(0.8) : .secondaryLabelColor
        let tint: NSColor = own ? ink.withAlphaComponent(0.2) : .labelColor.withAlphaComponent(0.08)
        let styled = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let all = NSRange(location: 0, length: styled.length), string = styled.string as NSString
        for match in links.matches(in: text, range: all) {
            if let url = match.url { styled.addAttribute(.link, value: url, range: match.range) }
        }
        let ranges = formatting.filter { $0.start >= 0 && $0.length > 0 && $0.start + $0.length <= all.length }
        var bullets = IndexSet()
        var inserts: [(at: Int, text: String, like: Int)] = []   // text added around a chip, styled as the character `like`
        for range in ranges {   // fonts and blocks first; bold and italic then add traits to whichever font is there
            let r = NSRange(location: range.start, length: range.length), paragraph = string.paragraphRange(for: r)
            switch range.style {
            case .code: styled.addAttributes([.font: mono, .backgroundColor: tint], range: r)
            case .codeBlock:
                styled.addAttribute(.font, value: mono, range: r)
                styled.addAttributes([.paragraphStyle: indented(8, tail: 8), codeFillKey: tint], range: paragraph)
            case .heading: styled.addAttribute(.font, value: NSFont.systemFont(ofSize: 17, weight: .semibold), range: r)
            case .small: styled.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: r)
            case .nowrap:
                let line = NSMutableParagraphStyle(); line.lineBreakMode = .byTruncatingTail
                styled.addAttribute(.paragraphStyle, value: line, range: paragraph)
            case .strike: styled.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            case .underline: styled.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            case .link(let url): styled.addAttribute(.link, value: url, range: r)
            case .quote:
                styled.addAttribute(.foregroundColor, value: secondary, range: r)
                styled.addAttributes([.paragraphStyle: indented(12), quoteBarKey: secondary], range: paragraph)
            case .listItem:
                let indent = NSMutableParagraphStyle(); indent.headIndent = 12
                styled.addAttribute(.paragraphStyle, value: indent, range: paragraph)
                bullets.insert(paragraph.location)
            case .mention(let id):   // one person's mention carries their id, for the card a click shows
                if !own { styled.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: r) }
                if let id, id != TextStyleRange.everyone { styled.addAttributes([mentionKey: id, .cursor: NSCursor.pointingHand], range: r) }
            case .customEmoji(let emoji): styled.addAttribute(customEmojiKey, value: emoji, range: r)
            case .color(let argb): styled.addAttribute(.foregroundColor, value: NSColor(rgb: argb & 0xFF_FFFF), range: r)   // as is, as web shows it
            case .chip(let room, let emoji, _):   // Google Chat's pill: the space's emoji and name on a tint, rounded where drawn
                styled.addAttributes([chipKey: ChatLink.url(room), .backgroundColor: tint, .cursor: NSCursor.pointingHand], range: r)
                inserts.append((NSMaxRange(r), "\u{2009}", r.location + r.length - 1))
                inserts.append((r.location, "\u{2009}" + (emoji.map { $0 + "\u{2009}" } ?? ""), r.location))
            case .bold, .italic: break
            }
        }
        for range in ranges {
            let trait: NSFontDescriptor.SymbolicTraits
            switch range.style { case .bold, .mention: trait = .bold; case .italic: trait = .italic; default: continue }
            let r = NSRange(location: range.start, length: range.length)
            styled.enumerateAttribute(.font, in: r) { value, sub, _ in
                guard let current = value as? NSFont else { return }
                let descriptor = current.fontDescriptor.withSymbolicTraits(current.fontDescriptor.symbolicTraits.union(trait))
                styled.addAttribute(.font, value: NSFont(descriptor: descriptor, size: current.pointSize) ?? current, range: sub)
            }
        }
        var emoji: [(CustomEmoji, Int)] = []   // replaced from the end, after the styles, so earlier offsets stay valid
        styled.enumerateAttribute(customEmojiKey, in: all) { value, range, _ in
            guard let value = value as? CustomEmoji else { return }
            for i in range.location..<NSMaxRange(range) where string.character(at: i) == 0xFFFD { emoji.append((value, i)) }
        }
        for (value, i) in emoji.reversed() {
            var attributes = styled.attributes(at: i, effectiveRange: nil); attributes[customEmojiKey] = nil
            styled.replaceCharacters(in: NSRange(location: i, length: 1), with: customEmoji(value, attributes: attributes))
        }
        inserts += bullets.map { ($0, "• ", $0) }
        for insert in inserts.sorted(by: { $0.at > $1.at }) {   // from the end, so earlier offsets stay valid
            styled.insert(NSAttributedString(string: insert.text, attributes: styled.attributes(at: insert.like, effectiveRange: nil)), at: insert.at)
        }
        if let quote {
            let style = indented(12)
            let header = NSMutableAttributedString(string: quote.sender + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: secondary, .paragraphStyle: style, quoteBarKey: secondary])
            let quoted = NSMutableAttributedString(string: quote.text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: secondary, .paragraphStyle: style, quoteBarKey: secondary])
            for range in (quote.emoji ?? []).sorted(by: { $0.start > $1.start }) where range.start + range.length < quoted.length {   // as pictures
                guard case .customEmoji(let emoji) = range.style else { continue }
                let at = NSRange(location: range.start, length: range.length)
                quoted.replaceCharacters(in: at, with: customEmoji(emoji, attributes: quoted.attributes(at: at.location, effectiveRange: nil)))
            }
            header.append(quoted)
            styled.insert(header, at: 0)
        }
        styledCache.setObject(styled, forKey: key as NSString)
        return styled
    }
    /// A custom emoji at the size of the text around it: its image once `ImageCache` has it (a faint square until then,
    /// so loading never moves the layout), or ":shortcode:" when it was deleted or has no image.
    static func customEmoji(_ emoji: CustomEmoji, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        guard !emoji.deleted, let picture = emoji.image else { return NSAttributedString(string: emoji.text, attributes: attributes) }
        let font = attributes[.font] as? NSFont ?? self.font
        let placeholder = (attributes[.foregroundColor] as? NSColor ?? .labelColor).withAlphaComponent(0.15)
        let side = ceil(font.ascender - font.descender)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            // Drawn on the main thread by the text view or label; `MessageRowView` redraws once the picture arrives.
            if Thread.isMainThread, let loaded = MainActor.assumeIsolated({ ImageCache.cached(picture) }), loaded.size.width > 0, loaded.size.height > 0 {
                let scale = min(rect.width / loaded.size.width, rect.height / loaded.size.height)
                let size = NSSize(width: loaded.size.width * scale, height: loaded.size.height * scale)
                loaded.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            } else {
                placeholder.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            }
            return true
        }
        image.cacheMode = .never   // the drawing handler decides each time: placeholder, then the picture
        image.accessibilityDescription = emoji.text
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: font.descender, width: side, height: side)
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttributes(attributes, range: NSRange(location: 0, length: result.length))
        result.addAttribute(emojiKey, value: emoji, range: NSRange(location: 0, length: result.length))   // for its hover card
        return result
    }
    /// A paragraph block: a leading bar (quotes) or a tinted background (code).
    /// Every line of a quote or code block indented alike (TextKit's text blocks indented only the first line in a
    /// timeline row); `MessageLayoutManager` draws the quote's bar and the code's background over the block's lines.
    private static func indented(_ indent: CGFloat, tail: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent; style.headIndent = indent; style.tailIndent = -tail; style.paragraphSpacing = 2
        return style
    }
    /// On a quote's lines: the colour of the bar drawn beside them.
    static let quoteBarKey = NSAttributedString.Key("Parley.message.quoteBar")
    /// On a code block's lines: the colour of the background drawn behind them.
    static let codeFillKey = NSAttributedString.Key("Parley.message.codeFill")
    private static var font: NSFont { .systemFont(ofSize: 14) }   // computed: NSFont isn't Sendable, and AppKit caches fonts
    private static var mono: NSFont { .monospacedSystemFont(ofSize: 13, weight: .regular) }
    private static let links = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private nonisolated(unsafe) static let styledCache = NSCache<NSString, NSAttributedString>()   // NSCache is thread-safe
}

extension ComposerTextView {
    /// The field's height for its wrapped text, so one long paragraph grows it the way several lines do.
    var contentHeight: CGFloat {
        guard let manager = layoutManager, let container = textContainer else { return 0 }
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height) + textContainerInset.height * 2
    }
    func reportHeight() {
        guard bounds.width > 0 else { return }   // not laid out yet: everything would wrap
        let height = contentHeight
        guard height != reportedHeight else { return }
        reportedHeight = height
        heightChanged?(height)
    }
}
