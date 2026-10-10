import AppKit
import Quartz
import SwiftUI

/// The message list, laid out like Telegram for macOS's chat: every row's height and
/// element frames come from a `RowLayout` computed for the table width, rows are frame-laid-out AppKit views
/// (`MessageRowView`), updates are diffs (older pages inserted above, new messages appended), and after every change
/// the first visible row is put back at its exact offset, or the view stays at the bottom when the reader was there.
struct MessageTable: NSViewRepresentable {
    let rows: [TimelineRow]
    let meID: String
    let kind: ConversationKind
    var style = TimelineStyle.bubbles
    /// The wallpaper and bubble colour settings: rows redraw when either changes.
    var look = ""
    var highlighted: MessageID?
    var identifier = "timeline"
    let actions: MessageRowActions
    /// Called when the reader scrolls into the top zone (three screens, `Coordinator.topZone`), and again after each
    /// change to the rows while still in it.
    let nearTop: () -> Void
    /// Whether the newest message is within a screen; drives the scroll-to-bottom button.
    var atBottomChanged: (Bool) -> Void = { _ in }
    /// Bumped to scroll smoothly to the newest message (the scroll-to-bottom button).
    var scrollRequest = 0
    /// Height of what floats over the bottom of the timeline (the composer): the newest message rests just above it.
    var bottomInset: CGFloat = 0

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView { Self.makeScrollView(context.coordinator, identifier: identifier) }
    static func makeScrollView(_ coordinator: Coordinator, identifier: String) -> NSScrollView {
        let table = TimelineTableView()
        table.swipeHandler = { [weak coordinator] event in coordinator?.handleSwipe(event) ?? false }
        table.files = coordinator.files
        coordinator.files.responder = table
        coordinator.files.messages = { [weak coordinator] in coordinator?.rows.map(\.message) ?? [] }
        table.addTableColumn(NSTableColumn(identifier: .init("message")))
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero   // gaps are part of each RowLayout
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = coordinator
        table.delegate = coordinator
        let scroll = NSScrollView()
        scroll.documentView = table
        // The table sizes its own height to its rows. Under SwiftUI its autoresizing mask becomes constraints, and a
        // layout pass then writes back a height from before the rows were re-measured, hiding the newest under the composer.
        table.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true   // no empty legacy scroller track beside a short conversation
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false   // the bottom inset follows the composer (`bottomInset`)
        scroll.contentView.automaticallyAdjustsContentInsets = false   // the clip view would otherwise reset it to the safe area
        scroll.setAccessibilityIdentifier(identifier)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        table.postsFrameChangedNotifications = true   // the table's own width, which settles after the clip view's
        NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.tableResized), name: NSView.frameDidChangeNotification, object: table)
        NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.liveResizeEnded), name: NSWindow.didEndLiveResizeNotification, object: nil)
        coordinator.scroll = scroll
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(self) }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var scroll: NSScrollView?
        private var parent: MessageTable?
        private(set) var rows: [TimelineRow] = []
        private var layouts: [TimelineRow: RowLayout] = [:]
        private var measuredWidth: CGFloat = 0
        /// A live resize is under way: rows keep their layouts until it ends. Our own flag, because AppKit still reports
        /// `inLiveResize` while it posts the resize's end, which would keep the old layouts for the final re-measure.
        var resizing = false
        private var wasNearTop = false
        private var rowsAtNearTop = 0   // the row count when the table last asked for older history
        private var keeping = false
        /// Whether the reader is following the newest message. Only scrolling changes it, not layout passes: SwiftUI
        /// briefly lays the timeline out at transient sizes, which would otherwise read as having scrolled away.
        private(set) var pinnedToBottom = true
        private var lastClipSize: NSSize = .zero
        private var wasAtBottom = true
        private var highlighted: MessageID?
        var table: NSTableView? { scroll?.documentView as? NSTableView }
        /// Quick Look, drag out and the attachment menu for this timeline's attachments.
        let files = AttachmentFiles { _, _ in throw CancellationError() }
        private static let reportsForUITests = ProcessInfo.processInfo.arguments.contains("-uiTestingLongHistory")

        private(set) var updates = 0   // how often SwiftUI handed the table new rows: tests check that typing doesn't
        func update(_ parent: MessageTable) {
            updates += 1
            let changedLook = self.parent.map { $0.meID != parent.meID || $0.kind != parent.kind || $0.style != parent.style || $0.look != parent.look } ?? false
            let wantsBottom = self.parent.map { $0.scrollRequest != parent.scrollRequest } ?? false
            self.parent = parent
            files.load = parent.actions.loadAttachment
            guard let table, let scroll else { return }
            if scroll.contentInsets.bottom != parent.bottomInset {
                keepingPlace {
                    // The clip view clamps scrolling to its own insets, which the scroll view only copies on a later tile;
                    // until then a pinned reader is pulled back under the composer. Set both at once.
                    scroll.contentInsets.bottom = parent.bottomInset
                    scroll.contentView.contentInsets.bottom = parent.bottomInset
                    scroll.tile()
                }
            }
            if parent.rows != rows || changedLook {
                let old = rows
                let ownNew = parent.rows.last?.id != old.last?.id && parent.rows.last?.message.sender.id == parent.meID
                if changedLook { layouts = [:] }   // who "me" is decides alignment: cached layouts are for the old identity
                keepingPlace(toBottom: old.isEmpty || ownNew) { apply(old: old, new: parent.rows, everything: changedLook, in: table) }
                checkNearTop()   // a page landed and the reader may still be near the top: ask for the next one
            }
            if parent.highlighted != highlighted {
                let affected = [highlighted, parent.highlighted].compactMap { id in rows.firstIndex { $0.id == id } }
                highlighted = parent.highlighted
                affected.forEach(configureRow)
                if let id = parent.highlighted, let index = rows.firstIndex(where: { $0.id == id }) { table.scrollRowToVisible(index) }
            }
            if wantsBottom { scrollToBottom() }
        }
        /// Telegram-style diff: older rows inserted above, newer appended, changed rows re-measured and reconfigured in place.
        private func apply(old: [TimelineRow], new: [TimelineRow], everything: Bool, in table: NSTableView) {
            rows = new
            let oldIDs = old.map(\.id), newIDs = new.map(\.id)
            let prepended = newIDs.ends(with: oldIDs), appended = newIDs.starts(with: oldIDs)
            guard !everything, !old.isEmpty, prepended || appended else {
                prefetchQueue = []   // another conversation: the previous one's thumbnails are no longer wanted
                prefetchThumbnails(new)
                table.reloadData(); return
            }
            let offset = prepended ? newIDs.count - oldIDs.count : 0
            if prepended { prefetchThumbnails(new[..<offset]) }
            table.beginUpdates()
            if prepended, offset > 0 { table.insertRows(at: IndexSet(integersIn: 0..<offset), withAnimation: []) }
            else if new.count > old.count { table.insertRows(at: IndexSet(integersIn: old.count..<new.count), withAnimation: []) }
            let changed = IndexSet(old.indices.filter { old[$0] != new[$0 + offset] }.map { $0 + offset })
            if !changed.isEmpty { table.noteHeightOfRows(withIndexesChanged: changed) }
            table.endUpdates()
            changed.forEach(configureRow)
        }
        /// Runs a change, then puts the first row wholly in view back where it was, or stays at the bottom if the reader was
        /// there. The row is found again by id.
        private func keepingPlace(toBottom: Bool = false, _ change: () -> Void) {
            // Re-measuring resizes the table, whose frame change re-enters here mid-update; only the outermost call,
            // which saw the state before any of it, decides where the reader ends up.
            guard let scroll, let table, !keeping else { return change() }
            keeping = true
            defer { keeping = false }
            let visible = scroll.contentView.bounds
            let atBottom = toBottom || pinnedToBottom
            // Not the row cut off at the top: when it re-wraps (a resize), every row below would move by its change.
            let inView = table.rows(in: uncovered), top = uncovered.minY
            let first = (inView.location..<inView.location + inView.length).first { table.rect(ofRow: $0).minY >= top } ?? inView.location
            let anchor = first < rows.count ? (id: rows[first].id, offset: table.rect(ofRow: first).minY - visible.minY) : nil
            // NSTableView animates height changes from `noteHeightOfRows` (~0.25 s) while the scroll position below is
            // already final: rows slide and settle (a wiggle when a receipt moves, every row after a resize). Apply them
            // at once, as Telegram does.
            NSAnimationContext.beginGrouping(); NSAnimationContext.current.duration = 0
            change()
            NSAnimationContext.endGrouping()
            table.tile()   // out of Auto Layout (see makeScrollView), the table resizes to its rows only when tiled
            table.layoutSubtreeIfNeeded()
            var target: CGFloat
            if atBottom { target = bottomOrigin }
            else if let anchor, let index = rows.firstIndex(where: { $0.id == anchor.id }) { target = table.rect(ofRow: index).minY - anchor.offset }
            else { return }
            target = min(target, bottomOrigin)   // never past the content
            pinnedToBottom = atBottom
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(-scroll.contentInsets.top, target)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        /// Width changed. During a live resize only the visible rows are re-measured (the rest keep their last layout);
        /// `liveResizeEnded` re-measures everything, as Telegram does.
        @objc func tableResized() {
            guard let table, let scroll else { return }
            guard table.bounds.width != measuredWidth else { if pinnedToBottom { keepingPlace {} }; return }   // grew taller: follow
            measuredWidth = table.bounds.width
            if scroll.inLiveResize { resizing = true }
            let visible = table.rows(in: scroll.documentVisibleRect)
            let indexes = resizing ? IndexSet(integersIn: visible.location..<visible.location + visible.length)
                                   : IndexSet(integersIn: 0..<rows.count)
            // Mid-resize, as TelegramSwift's TableView does: the rows in view are measured again at the new width and
            // redrawn with it, so none shows clipped; rows out of view keep their layouts until the resize ends.
            if resizing { for i in indexes where i < rows.count { layouts[rows[i]] = nil } }
            keepingPlace { table.noteHeightOfRows(withIndexesChanged: indexes) }
            if resizing { indexes.forEach(configureRow) }
            if scroll.inLiveResize { settleAfterResize() }
        }
        /// An animated resize (a pane opening grows the window, the zoom button) is a live resize that never posts its
        /// end: once resizing stops, re-measure every row. A drag still going on is left to `liveResizeEnded`.
        private var settle: Task<Void, Never>?
        private func settleAfterResize() {
            settle?.cancel()
            settle = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self, let table, let scroll, !scroll.inLiveResize else { return }
                resizing = false
                keepingPlace { table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count)) }
            }
        }
        @objc func liveResizeEnded(_ note: Notification) {
            guard let table, let window = scroll?.window, note.object as? NSWindow === window else { return }
            resizing = false
            keepingPlace { table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count)) }
        }
        /// The clip view's origin with the newest message resting just above the bottom inset.
        private var bottomOrigin: CGFloat {
            guard let scroll, let table else { return 0 }
            return table.bounds.height + scroll.contentInsets.bottom - scroll.contentView.bounds.height
        }
        /// The part of the document not covered by the content insets (the toolbar above, the composer below).
        private var uncovered: NSRect {
            guard let scroll else { return .zero }
            let insets = scroll.contentInsets, bounds = scroll.contentView.bounds
            return NSRect(x: bounds.minX, y: bounds.minY + insets.top, width: bounds.width, height: max(0, bounds.height - insets.top - insets.bottom))
        }
        @objc func scrolled() {
            guard let scroll, let table else { return }
            let visible = uncovered
            let clipSize = scroll.contentView.bounds.size
            if !keeping && clipSize == lastClipSize { pinnedToBottom = visible.maxY >= table.bounds.height - 40 }   // a scroll, not a resize
            lastClipSize = clipSize
            if !keeping { checkNearTop() }   // mid-update the offset is transient; `update` checks once it settles
            let atBottom = visible.maxY >= table.bounds.height - visible.height   // within one screen of the newest message
            if atBottom != wasAtBottom {   // after the current update: this runs while SwiftUI updates the table (keeping place)
                wasAtBottom = atBottom
                let report = parent?.atBottomChanged
                Task { @MainActor in report?(atBottom) }
            }
            if Self.reportsForUITests {   // one cheap value to poll instead of querying rows
                let middle = table.row(at: NSPoint(x: 1, y: visible.midY))
                scroll.setAccessibilityValue("\(rows.indices.contains(middle) ? rows[middle].id : "") of \(rows.count)")
            }
        }
        /// Asks for older history when the reader is within `topZone` of the top: on entering the zone, and again each time
        /// rows change while still in it, so a fast scroll keeps paging instead of stalling at the top (as Telegram does).
        /// A page that adds no rows asks nothing more until the reader leaves and re-enters the zone; the store drops
        /// requests while one is in flight or when there is no more history.
        private func checkNearTop() {
            guard scroll != nil, !rows.isEmpty else { wasNearTop = false; return }
            let visible = uncovered
            let nearTop = visible.minY < Self.topZone(visibleHeight: visible.height)
            if nearTop && (!wasNearTop || rows.count != rowsAtNearTop) {
                rowsAtNearTop = rows.count
                parent?.nearTop()
            }
            wasNearTop = nearTop
        }
        /// Three screens of history above the reader, at least 600 pt.
        static func topZone(visibleHeight: CGFloat) -> CGFloat { max(600, visibleHeight * 3) }

        /// Thumbnails of a page that just landed, warmed into `ImageCache` before their rows scroll into view;
        /// at most `prefetchLimit` at a time, nearest to the reader first, best effort.
        private var prefetchQueue: [Attachment] = []
        private var prefetchers = 0
        static let prefetchLimit = 4
        private func prefetchThumbnails(_ rows: some Collection<TimelineRow>) {
            prefetchQueue += rows.flatMap(\.message.attachments).filter { $0.kind == .image || $0.kind == .video }
            while prefetchers < Self.prefetchLimit, !prefetchQueue.isEmpty {
                prefetchers += 1
                Task { [weak self] in
                    while let attachment = self?.prefetchQueue.popLast(), let load = self?.parent?.actions.loadAttachment {
                        _ = try? await ImageCache.load(attachment, load)
                    }
                    self?.prefetchers -= 1
                }
            }
        }
        func scrollToBottom() {
            guard let scroll, table != nil else { return }
            pinnedToBottom = true
            let target = NSPoint(x: 0, y: max(-scroll.contentInsets.top, bottomOrigin))
            // An animation only advances with frames on screen: hidden, occluded or locked, jump instead of stalling.
            guard scroll.window?.occlusionState.contains(.visible) == true else {
                scroll.contentView.setBoundsOrigin(target); scroll.reflectScrolledClipView(scroll.contentView); return
            }
            NSAnimationContext.runAnimationGroup { _ in scroll.contentView.animator().setBoundsOrigin(target) }
        }

        /// The row's layout at the current width. Mid-resize, rows out of view keep their previous layout.
        func layout(_ row: TimelineRow) -> RowLayout? {
            guard let parent, let table, table.bounds.width > 50 else { return nil }
            if let cached = layouts[row], cached.width == table.bounds.width || resizing { return cached }
            let layout = RowLayout.make(row, width: table.bounds.width, own: row.message.sender.id == parent.meID, kind: parent.kind, style: parent.style)
            layouts[row] = layout
            return layout
        }
        private func configureRow(_ index: Int) {
            guard let view = table?.rowView(atRow: index, makeIfNecessary: false) as? MessageRowView else { return }
            configure(view, index)
        }
        private func configure(_ view: MessageRowView, _ index: Int) {
            guard let parent else { return }
            let row = rows[index]
            var actions = parent.actions
            actions.files = files
            view.configure(row, own: row.message.sender.id == parent.meID, kind: parent.kind, meID: parent.meID,
                           layout: layout(row), highlighted: row.id == parent.highlighted, style: parent.style, actions: actions)
        }

        // MARK: Swipe to reply (Telegram's chat gesture; logic in ReplySwipe)
        private var swipe = ReplySwipe()
        private var swipingRow: Int?
        /// Returns true when the event belongs to a reply swipe and must not scroll the table.
        func handleSwipe(_ event: NSEvent) -> Bool {
            guard event.hasPreciseScrollingDeltas, let table else { return false }   // trackpad only, as Telegram
            // Positive moves toward the reply arrow (fingers moving left), whichever way natural scrolling is set.
            let toward = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaX : event.scrollingDeltaX
            let width = table.bounds.width
            if event.phase == .began {
                let row = table.row(at: table.convert(event.locationInWindow, from: nil))
                guard row >= 0, !rows[row].message.isSystem, swipe.handle(.began, towardReply: toward, vertical: event.scrollingDeltaY, width: width) == .began else { return false }
                swipingRow = row
                swipe.allowsThread = parent?.identifier != "thread"   // inside a thread only quote applies
                return true
            }
            guard let index = swipingRow, let view = table.rowView(atRow: index, makeIfNecessary: false) as? MessageRowView else { return false }
            switch swipe.handle(event.phase, towardReply: toward, vertical: event.scrollingDeltaY, width: width) {
            case let .moved(offset, stage, crossed):
                if crossed { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                view.setSwipe(offset: offset, stage: stage)
            case let .committed(stage):
                settle(view)
                guard rows.indices.contains(index), let actions = parent?.actions else { break }
                if stage == .thread { actions.openThread(rows[index].message) } else { actions.quote(rows[index].message) }
            case .cancelled:
                settle(view)
            case .began, .ignore:
                return false
            }
            return true
        }
        private func settle(_ view: MessageRowView) {
            swipingRow = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2; context.allowsImplicitAnimation = true
                view.setSwipe(offset: 0, stage: nil)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { layout(rows[row])?.height ?? 44 }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = tableView.makeView(withIdentifier: .init("message"), owner: nil) as? MessageRowView ?? {
                let view = MessageRowView(); view.identifier = .init("message"); return view
            }()
            configure(view, row)
            return view
        }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    }
}

private extension Array where Element: Equatable {
    func ends(with suffix: [Element]) -> Bool { suffix.count <= count && Array(self[(count - suffix.count)...]) == suffix }
}

/// The timeline's table: offers trackpad scroll events to the reply swipe before scrolling, and controls the
/// Quick Look panel for its attachments (Space toggles it, as in Finder).
final class TimelineTableView: NSTableView {
    var swipeHandler: ((NSEvent) -> Bool)?
    weak var files: AttachmentFiles?
    override func scrollWheel(with event: NSEvent) {
        if swipeHandler?(event) != true { super.scrollWheel(with: event) }
    }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", files?.togglePreview() == true { return }
        super.keyDown(with: event)
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { MainActor.assumeIsolated { files?.previewItems.isEmpty == false } }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { MainActor.assumeIsolated { files?.beginControl(panel) } }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { MainActor.assumeIsolated { files?.endControl(panel) } }
}
