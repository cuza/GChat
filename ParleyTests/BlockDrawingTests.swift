import AppKit
import Testing
@testable import Parley

/// Quotes and code blocks as a timeline row draws them: every line indented alike, the quote's bar (or the code's
/// background) beside all of its lines. TextKit's own text blocks indented only a block's first line there.
@MainActor struct BlockDrawingTests {
    private func row(_ style: TextStyleRange.Style) -> MessageTextView {
        var message = Message(id: "m", conversationID: "c", sender: Person(id: "a", name: "X"), text: "quote line one\nquote line two\nafter the quote")
        message.formatting = [TextStyleRange(style: style, start: 0, length: 30)]
        let row = TimelineRow.rows([message])[0]
        let view = MessageRowView()
        view.configure(row, own: false, kind: .direct, meID: "me", actions: MessageRowActions())
        view.frame = CGRect(x: 0, y: 0, width: 700, height: RowLayout.make(row, width: 700, own: false, kind: .direct).height)
        view.layoutSubtreeIfNeeded()
        view.textView.layoutManager?.ensureLayout(for: view.textView.textContainer!)
        return view.textView
    }
    private func lineStart(_ view: MessageTextView, _ character: Int) -> CGFloat {
        let manager = view.layoutManager!
        return manager.lineFragmentUsedRect(forGlyphAt: manager.glyphIndexForCharacter(at: character), effectiveRange: nil).minX
    }
    private func inked(_ view: MessageTextView, x: Int, line character: Int, above alpha: CGFloat = 0.1) -> Bool {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let manager = view.layoutManager!
        let fragment = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: character), effectiveRange: nil)
        let scale = rep.size.height > 0 ? CGFloat(rep.pixelsHigh) / rep.size.height : 1
        return (rep.colorAt(x: Int(CGFloat(x) * scale), y: Int(fragment.midY * scale))?.alphaComponent ?? 0) > alpha
    }
    @Test func aQuoteIndentsAndBarsEveryLine() {
        let view = row(.quote)
        #expect(lineStart(view, 0) > 4 && lineStart(view, 15) == lineStart(view, 0))   // both quoted lines
        #expect(lineStart(view, 30) == 0)                                               // the line after it
        #expect(inked(view, x: 1, line: 0) && inked(view, x: 1, line: 15))              // the bar beside both
        #expect(!inked(view, x: 1, line: 30))
    }
    @Test func aCodeBlockIndentsAndFillsEveryLine() {
        let view = row(.codeBlock)
        #expect(lineStart(view, 0) > 4 && lineStart(view, 15) == lineStart(view, 0))
        #expect(inked(view, x: 1, line: 15, above: 0.03) && !inked(view, x: 1, line: 30, above: 0.03))   // a faint tint
    }
    /// A long code block fits its bubble: the row's text view lays it out in no more lines than it was measured with.
    @Test func aLongCodeBlockIsNotCutOff() {
        let code = "[sso-session example]\nsso_start_url = https://example-1234567890abcdef.portal.us-east-1.app.aws\nsso_region = us-east-1\n\n"
            + (1...4).map { "[profile p\($0)]\nsso_session = example\nsso_account_id = 123456789012\nsso_role_name = AdministratorAccess\nregion = us-west-2" }.joined(separator: "\n\n")
        var message = Message(id: "m", conversationID: "c", sender: Person(id: "a", name: "X"), text: code)
        message.formatting = [TextStyleRange(style: .codeBlock, start: 0, length: (code as NSString).length)]
        let row = TimelineRow.rows([message])[0]
        let view = MessageRowView()
        view.configure(row, own: true, kind: .direct, meID: "a", actions: MessageRowActions())
        view.frame = CGRect(x: 0, y: 0, width: 800, height: RowLayout.make(row, width: 800, own: true, kind: .direct).height)
        view.layoutSubtreeIfNeeded()
        let text = view.textView, manager = text.layoutManager!
        manager.ensureLayout(for: text.textContainer!)
        #expect(manager.usedRect(for: text.textContainer!).height <= text.frame.height + 0.5)
    }
}
