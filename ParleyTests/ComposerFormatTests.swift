import AppKit
import Testing
@testable import Parley

/// Underline, text colour, code blocks, quotes and links, sent as Google Chat's web composer sends them.
struct FormatAnnotationTests {
    @Test func colourIsFontColorWithItsARGBValue() throws {
        let sent = DynamiteMapper.annotations([TextStyleRange(style: .color(TextColor.red.argb), start: 0, length: 3)])
        let one = try #require(sent.first)
        #expect(sent.count == 1 && one.type == .formatData && one.formatMetadata.formatType == .fontColor)
        #expect(one.formatMetadata.fontColor == 0xFFF4_4336 && one.startIndex == 0 && one.length == 3)
        #expect(TextColor.allCases.map(\.argb) == [0xFFF4_4336, 0xFF21_96F3, 0xFF4C_AF50, 0xFFFF_C107, 0xFF9E_9E9E])
    }
    @Test func blocksAndUnderlineKeepTheirTypes() {
        let sent = DynamiteMapper.annotations([TextStyleRange(style: .underline, start: 0, length: 1),
                                               TextStyleRange(style: .codeBlock, start: 2, length: 6),
                                               TextStyleRange(style: .quote, start: 8, length: 6)])
        #expect(sent.map(\.formatMetadata.formatType) == [.underline, .monospaceBlock, .quoteBlock])
        #expect(sent.map(\.length) == [1, 6, 6])
    }
    @Test func aLinkIsARichTextURLOverItsText() throws {
        let sent = DynamiteMapper.annotations([TextStyleRange(style: .link(URL(string: "https://example.com/a")!), start: 4, length: 4)])
        let link = try #require(sent.first)
        #expect(link.type == .url && link.startIndex == 4 && link.length == 4 && link.chipRenderType == .render)
        #expect(link.urlMetadata.url.url == "https://example.com/a" && link.urlMetadata.urlSource == .richText && link.urlMetadata.hasShouldNotRender && !link.urlMetadata.shouldNotRender)
    }
    @Test func theLinkFormTakesAddressesAsTyped() {
        #expect(LinkForm.url("example.com/a") == URL(string: "https://example.com/a"))
        #expect(LinkForm.url(" http://a.b ") == URL(string: "http://a.b"))
        #expect(LinkForm.url("mailto:a@b.c") == URL(string: "mailto:a@b.c"))
        #expect(LinkForm.url("") == nil && LinkForm.url("two words") == nil)
    }
    @Test func aReceivedColourShowsAsIs() throws {
        let annotation = Dynamite_Annotation.with { a in
            a.type = .formatData; a.startIndex = 0; a.length = 2; a.formatMetadata = .with { $0.formatType = .fontColor; $0.fontColor = 0xFF12_3456 }
        }
        let shown = DynamiteMapper.richText("hi there", [annotation])
        #expect(shown.formatting == [TextStyleRange(style: .color(0xFF12_3456), start: 0, length: 2)])
        let styled = MessageTextStyle.styled(shown.text, shown.formatting, own: false)
        let colour = try #require(styled.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        #expect(colour.usingColorSpace(.sRGB)?.redComponent ?? 0 > 0.06 && colour.usingColorSpace(.sRGB)?.redComponent ?? 1 < 0.08)
    }
}

@MainActor struct ComposerFormatTests {
    private func composer(_ text: String) -> (ComposerTextView, NSWindow) {
        let scroll = NativeComposer.makeScrollView(delegate: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80), styleMask: [], backing: .buffered, defer: false)
        window.contentView = scroll
        let view = scroll.documentView as! ComposerTextView
        view.load(text, [])
        window.makeFirstResponder(view)
        return (view, window)
    }
    /// The store never replaces the field's text under an input method's unfinished text (an accent being typed, an
    /// inline prediction): the composition would land in the replaced text and repeat words.
    @Test func theFieldIsNotReloadedWhileComposing() {
        let (view, _) = composer("hola")
        #expect(view.acceptsReload)
        view.setSelectedRange(NSRange(location: 4, length: 0))
        view.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!view.acceptsReload)
        view.unmarkText()
        #expect(view.acceptsReload)
    }
    @Test func underlineAndColourGoOnTheSelection() {
        let (view, _) = composer("hi there")
        view.setSelectedRange(NSRange(location: 0, length: 2))
        view.toggle(.underline)
        view.setSelectedRange(NSRange(location: 3, length: 5))
        view.color(.blue)
        #expect(Set(view.formatting) == [TextStyleRange(style: .underline, start: 0, length: 2), TextStyleRange(style: .color(TextColor.blue.argb), start: 3, length: 5)])
        view.color(nil)   // the default swatch takes the colour off
        #expect(view.formatting == [TextStyleRange(style: .underline, start: 0, length: 2)])
    }
    @Test func theCurrentColourIsTheSelectionsOrWhatIsTypedNext() {
        let (view, _) = composer("hi there")
        #expect(view.currentColor == nil)
        view.setSelectedRange(NSRange(location: 3, length: 5))
        view.color(.green)
        #expect(view.currentColor == .green)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(view.currentColor == nil)
        view.color(.red)   // at a caret: for what is typed next
        #expect(view.currentColor == .red)
    }
    /// One range per block over whole lines, its newline included unless it ends the message, as web sends it.
    @Test func codeBlocksAndQuotesCoverWholeLines() {
        let (view, _) = composer("c1\nc2\nx\nq1\nq2")
        view.setSelectedRange(NSRange(location: 1, length: 3))   // from "c1" into "c2"
        view.toggle(.codeBlock)
        view.setSelectedRange(NSRange(location: 9, length: 0))   // a caret in "q1"…
        view.setSelectedRange(NSRange(location: 9, length: 4))   // …to "q2"
        view.toggle(.quote)
        #expect(Set(view.formatting) == [TextStyleRange(style: .codeBlock, start: 0, length: 6), TextStyleRange(style: .quote, start: 8, length: 5)])
    }
    @Test func aLinkGoesOnTheSelectionOrInsertsItsText() {
        let (view, _) = composer("see docs")
        view.setSelectedRange(NSRange(location: 4, length: 4))
        view.link(URL(string: "https://example.com")!, text: nil)
        #expect(view.formatting == [TextStyleRange(style: .link(URL(string: "https://example.com")!), start: 4, length: 4)])
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.link(URL(string: "https://a.b")!, text: "here")
        #expect(view.string == "heresee docs" && view.formatting.contains(TextStyleRange(style: .link(URL(string: "https://a.b")!), start: 0, length: 4)))
    }
    @Test func editingKeepsColourAndLinks() {
        let (view, _) = composer("")
        let link = URL(string: "https://example.com")!
        view.load("red link", [TextStyleRange(style: .color(TextColor.red.argb), start: 0, length: 3), TextStyleRange(style: .link(link), start: 4, length: 4)])
        #expect(Set(view.formatting) == [TextStyleRange(style: .color(TextColor.red.argb), start: 0, length: 3), TextStyleRange(style: .link(link), start: 4, length: 4)])
    }
    @Test func shortcutsFormatTheSelection() throws {
        let (view, _) = composer("abc")
        view.setSelectedRange(NSRange(location: 0, length: 3))
        func press(_ key: String, _ flags: NSEvent.ModifierFlags) throws -> Bool {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: view.window!.windowNumber,
                                                       context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0))
            return view.performKeyEquivalent(with: event)
        }
        #expect(try press("u", .command))
        #expect(view.formatting == [TextStyleRange(style: .underline, start: 0, length: 3)])
        var asked = false
        view.askForLink = { asked = true }
        #expect(try press("k", .command))   // in the composer ⌘K makes a link; elsewhere it opens Jump to Conversation
        #expect(asked)
    }
    @Test func rightClickOffersAFormatMenu() throws {
        let (view, _) = composer("abc")
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: view.window!.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let format = try #require(view.menu(for: event)?.items.first { $0.title == "Format" }?.submenu)
        let titles = format.items.map(\.title)
        for title in ["Bold", "Italic", "Underline", "Strikethrough", "Text Color", "Code", "Code Block", "Quote", "Bulleted List", "Link…", "Clear Formatting"] {
            #expect(titles.contains(title), "\(title)")
        }
        #expect(format.items.first { $0.title == "Underline" }?.keyEquivalent == "u")
    }
}
