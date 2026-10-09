import AppKit
import SwiftUI
import Testing
@testable import Parley

/// Dragging the main window's dividers: the sidebar stops at its maximum and never squeezes the timeline, and the
/// side pane resizes within its bounds.
@MainActor struct PaneResizeTests {
    private func hosted(width: CGFloat = 1000) async -> (ChatStore, NSHostingView<ChatView>, NSWindow) {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let host = NSHostingView(rootView: ChatView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 650), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        await settle(host, window)
        return (store, host, window)
    }
    private func settle(_ host: NSView, _ window: NSWindow) async {
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try? await Task.sleep(for: .milliseconds(100)) }
    }
    private func splits(_ view: NSView) -> [NSSplitView] { ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splits) }

    private func timeline(in host: NSView) -> NSTableView? {
        func tables(_ view: NSView) -> [NSTableView] { (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables) }
        return tables(host).filter { $0.numberOfRows > 0 }.max { $0.bounds.width < $1.bounds.width }
    }

    @Test func theSidebarStopsAtItsMaximum() async throws {
        let (_, host, window) = await hosted()
        defer { window.close() }
        let split = try #require(splits(host).first)
        #expect(split.arrangedSubviews[0].frame.width == 230)   // its ideal width, not the split view's default
        split.setPosition(800, ofDividerAt: 0)
        await settle(host, window)
        #expect(split.arrangedSubviews[0].frame.width == ChatView.sidebarMaxWidth)
        #expect(split.convert(split.bounds, to: nil).maxX <= host.bounds.width)
    }
    /// With a pane open in a window just wide enough, widening the sidebar must not push the pane off the right edge.
    @Test func aWiderSidebarNeverSqueezesTheTimelineAndPane() async throws {
        let saved = UserDefaults.standard.object(forKey: "sidePaneWidth")   // the user's own dragged width
        UserDefaults.standard.removeObject(forKey: "sidePaneWidth")
        defer { UserDefaults.standard.set(saved, forKey: "sidePaneWidth") }
        let (store, host, window) = await hosted()
        defer { window.close() }
        store.info = true
        let split = try #require(splits(host).first)
        split.setPosition(ChatView.sidebarMinWidth, ofDividerAt: 0)
        window.setContentSize(NSSize(width: ChatView.minWidth(paneOpen: true, sidebar: ChatView.sidebarMinWidth) + 10, height: 650))
        await settle(host, window)
        split.setPosition(ChatView.sidebarMaxWidth, ofDividerAt: 0)
        await settle(host, window)
        let frame = split.convert(split.bounds, to: nil)
        #expect(frame.minX >= 0 && frame.maxX <= host.bounds.width, "\(frame) in \(host.bounds.width)")
    }
    @Test func thePaneTakesTheWidthItWasDraggedTo() async throws {
        let saved = UserDefaults.standard.object(forKey: "sidePaneWidth")
        UserDefaults.standard.set(480.0, forKey: "sidePaneWidth")
        defer { UserDefaults.standard.set(saved, forKey: "sidePaneWidth") }
        let (store, host, window) = await hosted(width: 1300)
        defer { window.close() }
        store.info = true
        await settle(host, window)
        let table = try #require(timeline(in: host))
        let edge = table.convert(table.bounds, to: nil).maxX
        #expect(abs(edge - (host.bounds.width - 481)) <= 20, "timeline ends at \(edge) in \(host.bounds.width)")
    }
    @Test func thePaneStaysWithinItsBoundsAndLeavesTheTimelineItsMinimum() {
        #expect(SidePaneSplit<EmptyView, EmptyView>.shown(wanted: 320, room: 0) == ChatView.paneWidth)   // not measured yet
        #expect(SidePaneSplit<EmptyView, EmptyView>.shown(wanted: 100, room: 1400) == ChatView.paneWidth)
        #expect(SidePaneSplit<EmptyView, EmptyView>.shown(wanted: 450, room: 1400) == 450)
        #expect(SidePaneSplit<EmptyView, EmptyView>.shown(wanted: 2000, room: 1400) == ChatView.paneMaxWidth)
        // A narrower window narrows the pane first, down to its minimum.
        #expect(SidePaneSplit<EmptyView, EmptyView>.shown(wanted: 500, room: 800) == 800 - ChatView.timelineMinWidth - 1)
        #expect(SidePaneSplit<EmptyView, EmptyView>.shown(wanted: 500, room: 600) == ChatView.paneWidth)
    }
}
