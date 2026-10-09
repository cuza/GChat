import AppKit
import Testing
@testable import Parley

@MainActor struct NativeTextTests {
    @Test func rerenderingTheSameTextKeepsTheSelection() {
        let view = NSTextView()
        NativeMessageText.show("hello there", own: false, in: view)
        view.setSelectedRange(NSRange(location: 0, length: 5))
        NativeMessageText.show("hello there", own: false, in: view)
        #expect(view.selectedRange() == NSRange(location: 0, length: 5))
    }
    @Test func detectsLinksAndFollowsOwnership() {
        let view = NSTextView()
        NativeMessageText.show("see https://example.com now", own: false, in: view)
        #expect(view.textStorage?.attribute(.link, at: 6, effectiveRange: nil) != nil)
        #expect(view.textStorage?.attribute(.link, at: 0, effectiveRange: nil) == nil)
        NativeMessageText.show("see https://example.com now", own: true, in: view)
        #expect(view.textColor == BubblePalette.ownInk)
        NativeMessageText.show("edited", own: true, in: view)
        #expect(view.string == "edited")
    }
    @Test func cachedSizeMatchesAFreshMeasurement() {
        let text = String(repeating: "wrap me please ", count: 20)
        let narrow = NativeMessageText.size(of: text, width: 120)
        #expect(narrow.height > NativeMessageText.size(of: text, width: 440).height)
        #expect(NativeMessageText.size(of: text, width: 120) == narrow)
    }
    private func traits(_ view: NSTextView, at index: Int) -> NSFontDescriptor.SymbolicTraits {
        (view.textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits ?? []
    }
    @Test func appliesInlineStyles() {
        let view = NSTextView()
        let formatting = [TextStyleRange(style: .bold, start: 0, length: 4), TextStyleRange(style: .italic, start: 2, length: 4),
                          TextStyleRange(style: .code, start: 7, length: 4), TextStyleRange(style: .strike, start: 12, length: 3),
                          TextStyleRange(style: .link(URL(string: "https://e.com")!), start: 16, length: 4)]
        NativeMessageText.show("bold ita code del link", formatting: formatting, own: false, in: view)
        #expect(traits(view, at: 0).contains(.bold) && !traits(view, at: 0).contains(.italic))
        #expect(traits(view, at: 3).isSuperset(of: [.bold, .italic]))
        #expect(traits(view, at: 8).contains(.monoSpace))
        #expect(view.textStorage?.attribute(.strikethroughStyle, at: 13, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        #expect(view.textStorage?.attribute(.link, at: 17, effectiveRange: nil) as? URL == URL(string: "https://e.com"))
        #expect(view.string == "bold ita code del link")
    }
    @Test func outOfBoundsStylesAreIgnored() {
        let view = NSTextView()
        NativeMessageText.show("hi", formatting: [TextStyleRange(style: .bold, start: 1, length: 5)], own: false, in: view)
        #expect(view.string == "hi" && !traits(view, at: 1).contains(.bold))
    }
    @Test func restylesWhenOnlyFormattingChanges() {
        let view = NSTextView()
        NativeMessageText.show("hello", own: false, in: view)
        NativeMessageText.show("hello", formatting: [TextStyleRange(style: .bold, start: 0, length: 5)], own: false, in: view)
        #expect(traits(view, at: 0).contains(.bold))
        view.setSelectedRange(NSRange(location: 0, length: 2))
        NativeMessageText.show("hello", formatting: [TextStyleRange(style: .bold, start: 0, length: 5)], own: false, in: view)
        #expect(view.selectedRange() == NSRange(location: 0, length: 2))
    }
    @Test func blocksListsAndQuotes() {
        let view = NSTextView()
        NativeMessageText.show("one\ntwo\nsaid\nfn()", formatting: [
            TextStyleRange(style: .listItem, start: 0, length: 3), TextStyleRange(style: .listItem, start: 4, length: 3),
            TextStyleRange(style: .quote, start: 8, length: 4), TextStyleRange(style: .codeBlock, start: 13, length: 4)
        ], quote: QuotedMessage(sender: "Alex", text: "orig"), own: false, in: view)
        #expect(view.string == "Alex\norig\n• one\n• two\nsaid\nfn()")
        // Quotes (the quoted message, and "said") carry a bar and an indent; the code block a background and an indent.
        func indent(_ at: Int) -> CGFloat { (view.textStorage?.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0 }
        #expect(view.textStorage?.attribute(MessageTextStyle.quoteBarKey, at: 0, effectiveRange: nil) != nil && indent(0) > 0)
        #expect(view.textStorage?.attribute(MessageTextStyle.quoteBarKey, at: 22, effectiveRange: nil) != nil && indent(22) > 0)
        #expect(view.textStorage?.attribute(MessageTextStyle.codeFillKey, at: 28, effectiveRange: nil) != nil && indent(28) > 0)
        #expect(traits(view, at: 28).contains(.monoSpace))
    }
    @Test func sizeDependsOnStyledContent() {
        let plain = NativeMessageText.size(of: "Title", width: 440)
        #expect(NativeMessageText.size(of: "Title", formatting: [TextStyleRange(style: .heading, start: 0, length: 5)], width: 440).height > plain.height)
        #expect(NativeMessageText.size(of: "Title", quote: QuotedMessage(sender: "Alex", text: "orig"), width: 440).height > plain.height)
    }
}
