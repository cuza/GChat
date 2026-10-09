import AppKit
import Foundation
import Testing
@testable import Parley

@MainActor struct ComposerFormattingTests {
    @Test func boldTogglesOnASelectionAndOff() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.load("hello world", [])
        view.setSelectedRange(NSRange(location: 6, length: 5))
        view.formatBold(nil)
        #expect(view.formatting == [TextStyleRange(style: .bold, start: 6, length: 5)])
        let font = view.textStorage?.attribute(.font, at: 7, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        view.formatBold(nil)
        #expect(view.formatting.isEmpty)
    }
    @Test func aStyleAtTheCaretAppliesToWhatIsTypedNext() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.load("a ", [])
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.formatCode(nil)
        view.insertText("x", replacementRange: view.selectedRange())
        #expect(view.formatting == [TextStyleRange(style: .code, start: 2, length: 1)])
    }
    @Test func listTogglesWholeLines() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.load("intro\none\ntwo", [])
        view.setSelectedRange(NSRange(location: 7, length: 4))   // "ne\ntw"
        view.formatList(nil)
        #expect(view.formatting == [TextStyleRange(style: .listItem, start: 6, length: 4), TextStyleRange(style: .listItem, start: 10, length: 3)])
    }
    @Test func loadingADraftRoundTripsItsFormatting() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        let formatting = [TextStyleRange(style: .bold, start: 3, length: 2), TextStyleRange(style: .italic, start: 4, length: 3),
                          TextStyleRange(style: .strike, start: 0, length: 2)]
        view.load("😀 hi there", formatting)
        #expect(Set(view.formatting) == Set(formatting))
    }
    @Test func pasteTakesPlainTextOnly() {
        #expect(ComposerTextView(usingTextLayoutManager: false).readablePasteboardTypes == [.string])
    }
}

@MainActor struct ComposerScrollerTests {
    /// With "Show scroll bars: Always" (or a mouse attached) scrollers are legacy and drawn whenever they are shown.
    @Test func theScrollerShowsOnlyWhenTheDraftOverflows() throws {
        let scroll = NativeComposer.makeScrollView(delegate: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 42), styleMask: [], backing: .buffered, defer: false)
        window.contentView = scroll
        scroll.scrollerStyle = .legacy
        let view = try #require(scroll.documentView as? ComposerTextView)
        func settle() { view.sizeToFit(); scroll.tile(); window.contentView?.layoutSubtreeIfNeeded() }
        view.load("one line", []); settle()
        #expect(scroll.verticalScroller?.isHidden != false, "a scroller shows beside a one-line draft")
        view.load(Array(repeating: "line", count: 20).joined(separator: "\n"), []); settle()
        #expect(scroll.verticalScroller?.isHidden == false, "a long draft has no scroller to scroll it with")
        view.load("", []); settle()
        #expect(scroll.verticalScroller?.isHidden != false, "a scroller shows beside an empty draft")
    }
}
