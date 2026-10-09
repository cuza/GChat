import AppKit
import SwiftUI
import Testing
@testable import Parley

/// Editing a sent message in the real composer, hosted, bound to the store as the timeline binds it.
@MainActor struct EditComposerTests {
    struct Harness: View {
        let store: ChatStore
        var body: some View {
            NativeComposer(text: store.drafts["alex/timeline"] ?? "", formatting: store.draftFormatting["alex/timeline"] ?? [],
                           change: { store.setDraft($0, formatting: $1, conversation: "alex", thread: nil) },
                           send: {}, editLast: {}, cancel: {})
                .frame(width: 400, height: 80)
                .overlay { Text(store.error ?? "") }   // lets a test redraw the view with nothing typed
        }
    }
    private func pump() { RunLoop.main.run(until: .now.addingTimeInterval(0.05)) }
    private func field(in view: NSView) -> ComposerTextView? {
        if let field = view as? ComposerTextView { return field }
        return view.subviews.lazy.compactMap(field).first
    }

    @Test func typingInsideAnEditedMessageStaysWhereTheCursorIs() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let mine = Message(id: "alex/mine", conversationID: "alex", sender: store.me, text: "Deja pregtarle")
        store.messages.append(mine)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Harness(store: store))
        pump()
        store.edit(mine)
        pump()
        let view = try #require(field(in: window.contentView!))
        #expect(view.string == mine.text)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        for letter in ["x", "y", "z"] {
            view.insertText(letter, replacementRange: view.selectedRange())
            pump()
        }
        let expected = String(mine.text.prefix(2)) + "xyz" + String(mine.text.dropFirst(2))
        #expect(view.string == expected && store.drafts["alex/timeline"] == expected)
        #expect(view.selectedRange().location == 5)
        try await Task.sleep(for: .seconds(1.5)); pump()   // any draft save or sync that comes back
        #expect(view.string == expected && view.selectedRange().location == 5)
    }

    @Test func markedTextWhileEditingIsCommittedOnce() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let mine = Message(id: "alex/mine", conversationID: "alex", sender: store.me, text: "Deja ")
        store.messages.append(mine)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Harness(store: store))
        pump(); store.edit(mine); pump()
        let view = try #require(field(in: window.contentView!))
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 5, length: 0))
        // An input method (or an inline prediction) composes "pregun", then commits "preguntarle".
        for step in ["p", "pr", "pre", "preg", "pregu", "pregun"] {
            view.setMarkedText(step, selectedRange: NSRange(location: step.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            pump()
        }
        view.insertText("preguntarle", replacementRange: NSRange(location: NSNotFound, length: 0))
        pump()
        #expect(view.string == "Deja preguntarle")
        #expect(store.drafts["alex/timeline"] == "Deja preguntarle")
    }

    @Test func aMessageWithFormattingTheComposerCantHoldStaysPutWhileEditing() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        var mine = Message(id: "alex/mine", conversationID: "alex", sender: store.me, text: "Deja pregtarle https://example.com")
        mine.formatting = [TextStyleRange(style: .link(URL(string: "https://example.com")!), start: 15, length: 19)]
        store.messages.append(mine)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Harness(store: store))
        pump(); store.edit(mine); pump()
        let view = try #require(field(in: window.contentView!))
        view.setSelectedRange(NSRange(location: 9, length: 0))
        store.error = "redraw"; pump()   // any redraw before the first key
        #expect(view.selectedRange().location == 9)
        view.insertText("un", replacementRange: view.selectedRange()); pump()
        #expect(view.string == "Deja preguntarle https://example.com")
    }
}

/// Provisional text (an input method's composition or an inline prediction) is not the draft until it is committed.
@MainActor struct ComposerMarkedTextTests {
    @Test func markedTextIsNotDraftTextAndALoadDiscardsIt() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NativeComposer.makeScrollView(delegate: nil)
        window.contentView = scroll
        let view = try #require(scroll.documentView as? ComposerTextView)
        window.makeFirstResponder(view)
        view.load("ai agent", [])
        view.setSelectedRange(NSRange(location: 8, length: 0))
        view.setMarkedText("nuest", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText() && view.string == "ai agentnuest")
        #expect(view.draftText == "ai agent")   // only what is committed
        view.unmarkText(); view.setSelectedRange(NSRange(location: 0, length: 2)); view.toggle(.bold)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.setMarkedText("xy", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.draftText == "ai agentnuest" && view.formatting == [TextStyleRange(style: .bold, start: 0, length: 2)])
        view.load("", [])                        // a send clears the field
        #expect(!view.hasMarkedText() && view.string.isEmpty)
    }
}

/// Typing updates only the composer: the timeline above it is not handed its rows again on each keystroke.
@MainActor struct ComposerIsolationTests {
    private func table(in view: NSView) -> NSTableView? { (view as? NSTableView) ?? view.subviews.lazy.compactMap(table).first }
    private func pump(_ seconds: Double = 0.05) { RunLoop.main.run(until: .now.addingTimeInterval(seconds)) }
    @Test func typingDoesNotUpdateTheTimeline() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let room = try #require(store.conversations.first { !store.timeline($0.id).isEmpty } ?? store.conversations.first)
        await store.select(room.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: TimelineView(store: store, conversation: room).frame(width: 700, height: 600))
        pump(0.3)
        let coordinator = try #require(table(in: window.contentView!)?.delegate as? MessageTable.Coordinator)
        store.setDraft("x", conversation: room.id, thread: nil); pump(0.2)   // a draft already started
        let before = coordinator.updates
        for text in ["h", "he", "hel", "hell", "hello"] {
            store.setDraft(text, conversation: room.id, thread: nil)
            pump()
        }
        #expect(coordinator.updates == before, "\(coordinator.updates - before) timeline updates for 5 keystrokes")
    }
}
