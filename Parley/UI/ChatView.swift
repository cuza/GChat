import AppKit
import SwiftUI

/// A space's emoji, else its photo or image, else initials (people) or # (spaces). Circle for people, rounded square for spaces.
struct Avatar: View {
    let name: String
    var space = false
    var size: CGFloat = 24
    var url: URL? = nil
    var emoji: String? = nil
    @State private var image: NSImage?
    @Environment(\.displayScale) private var scale
    private var hue: Double { Self.hue(name) }
    nonisolated static func hue(_ name: String) -> Double { Double(name.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % 360 }) / 360 }
    nonisolated static func initials(_ name: String) -> String { name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined() }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: space ? size * 0.27 : size / 2) }
    var body: some View {
        ZStack {
            if let emoji {
                shape.fill(.quaternary)
                Text(emoji).font(.system(size: size * 0.62))
            } else if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                shape.fill(Color(hue: hue, saturation: 0.35, brightness: 0.65))
                if space { Image(systemName: "number").font(.system(size: size * 0.52, weight: .medium)) }
                else { Text(Self.initials(name)).font(.system(size: size * 0.4, weight: .semibold, design: .rounded)) }
            }
        }.foregroundStyle(.white).frame(width: size, height: size).clipShape(shape).accessibilityHidden(true)
            .task(id: emoji == nil ? url : nil) {
                image = nil
                if emoji == nil, let url, let loaded = await RemoteImage.image(url, px: Int((size * scale).rounded())), !Task.isCancelled {
                    image = loaded   // a cancelled load (the row was recycled) must not blank the newer avatar
                }
            }
    }
}
/// Green when active, a hollow ring when away, red when not to be disturbed; nothing while unknown.
struct PresenceDot: View {
    let presence: Presence?
    var size: CGFloat = 8
    var body: some View {
        switch presence {
        case .available: Circle().fill(.green).frame(width: size, height: size).overlay(Circle().stroke(.background, lineWidth: 1.5)).accessibilityLabel("Active")
        case .away: Circle().strokeBorder(.secondary, lineWidth: 1.5).background(Circle().fill(.background)).frame(width: size, height: size).accessibilityLabel("Away")
        case .doNotDisturb: Circle().fill(.red).frame(width: size, height: size).overlay(Circle().stroke(.background, lineWidth: 1.5)).accessibilityLabel("Do not disturb")
        case .offline, nil: EmptyView()
        }
    }
}
struct ChatView: View {
    @Bindable var store: ChatStore
    var fixedConversation: String? = nil
    init(store: ChatStore, fixedConversation: String? = nil) {
        _store = Bindable(store); self.fixedConversation = fixedConversation
        _columns = State(initialValue: Self.initialColumns(fixedConversation: fixedConversation))
    }
    /// A conversation in its own window opens without the sidebar: there is nothing to choose there.
    static func initialColumns(fixedConversation: String?) -> NavigationSplitViewVisibility { fixedConversation == nil ? .all : .detailOnly }
    @State private var switcher = false
    @State private var composing = false   // the palette as New Chat
    @State private var searching = false
    @State private var columns: NavigationSplitViewVisibility
    @State private var sidebarAutoHidden = false   // hidden by us for a narrow window: it comes back when there is room
    @State private var width: CGFloat = 0
    @State private var sidebarWidth: CGFloat = 230   // as last measured while shown
    @State private var hostWindow = WindowRef()   // this view's own window
    @State private var leaving: Conversation?   // asks before leaving
    @AppStorage("collapsedSidebarSections") private var collapsedSections = ""   // titles, one per line
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openURL) private var openURL
    /// Posts a new Meet meeting in the conversation and opens it, as Google Chat's "Send a Meet link" does.
    private func sendMeetLink(_ id: ConversationID) { Task { if let url = await store.sendMeetLink(in: id) { openURL(url) } } }
    @Environment(SignInFlow.self) private var signIn: SignInFlow?
    private var room: Conversation? { store.conversations.first { $0.id == (fixedConversation ?? store.selectedID) } }
    /// `paneWidth` is the side pane's narrowest (and first) width; dragging its divider widens it up to `paneMaxWidth`.
    /// The sidebar's bounds take effect only as the column's outermost modifier: under another, the split view ignores them.
    static let paneWidth: CGFloat = 320, paneMaxWidth: CGFloat = 560, timelineMinWidth: CGFloat = 380, sidebarMinWidth: CGFloat = 180, sidebarMaxWidth: CGFloat = 300
    /// What the shown areas need: the sidebar at its width (0 when hidden), the timeline's minimum and, while open, the
    /// side pane. The split view keeps the sidebar's width as the window narrows and would clip the rest.
    static func minWidth(paneOpen: Bool, sidebar: CGFloat) -> CGFloat {
        sidebar + timelineMinWidth + (paneOpen ? 1 + paneWidth : 0)
    }
    /// As Mail does: a window too narrow for the sidebar hides it, and gives it back once it is wide enough again,
    /// unless the user hid it themselves.
    static func sidebar(width: CGFloat, paneOpen: Bool, sidebarWidth: CGFloat, visible: Bool, autoHidden: Bool) -> (visible: Bool, autoHidden: Bool) {
        let fits = width >= minWidth(paneOpen: paneOpen, sidebar: sidebarWidth)
        if visible, !fits { return (false, true) }
        if !visible, autoHidden, fits { return (true, false) }
        return (visible, autoHidden && !visible)
    }
    /// The sidebar's width as the window's needs count it: none in a conversation's own window or while hidden.
    static func shownSidebar(fixedConversation: String?, columns: NavigationSplitViewVisibility, measured: CGFloat) -> CGFloat {
        fixedConversation != nil || columns == .detailOnly ? 0 : measured
    }
    /// The window's width once a pane opens: grown only by what the shown areas lack.
    static func widthForPane(window: CGFloat, sidebar: CGFloat) -> CGFloat { max(window, minWidth(paneOpen: true, sidebar: sidebar)) }
    /// Widens the window to `wanted` (within the screen), if it is narrower.
    /// Only `window`, the view's own: every window shares the store, so each sees a pane open and must not resize another.
    static func makeRoom(_ wanted: CGFloat, in window: NSWindow?, animate: Bool = true) {
        guard let window, window.frame.width < wanted else { return }
        var frame = window.frame
        frame.size.width = min(wanted, window.screen?.visibleFrame.width ?? wanted)
        if let screen = window.screen?.visibleFrame { frame.origin.x = min(frame.origin.x, screen.maxX - frame.width) }
        window.setFrame(frame, display: true, animate: animate)
    }
    private func fitSidebar() {
        let next = Self.sidebar(width: width, paneOpen: store.info || store.threadID != nil, sidebarWidth: sidebarWidth,
                                visible: columns != .detailOnly, autoHidden: sidebarAutoHidden)
        if (columns != .detailOnly) != next.visible { columns = next.visible ? .all : .detailOnly }
        sidebarAutoHidden = next.autoHidden
    }
    @ViewBuilder private var sidebar: some View {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button { switcher = true } label: {
                        HStack { Image(systemName: "magnifyingglass"); Text("Jump to conversation"); Spacer(); Text("⌘K").font(.caption) }.foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                    Button { composing = true } label: { Image(systemName: "square.and.pencil").font(.system(size: 14)) }
                        .buttonStyle(.borderless).help("New Chat (⌘N)").accessibilityLabel("New Chat")
                }.padding(14)
                List(selection: Binding(get: { fixedConversation ?? store.shortcut.map(Self.tag) ?? store.selectedID }, set: { id in
                    guard let id else { return }
                    if let shortcut = Shortcut.allCases.first(where: { Self.tag($0) == id }) { Task { await store.openShortcut(shortcut) } }
                    else { Task { await store.select(id) } }
                })) {
                    ForEach(Conversation.sidebarSections(store.conversations), id: \.title) { section($0.title, rooms: $0.rooms) }
                }.listStyle(.sidebar).accessibilityIdentifier("sidebar")
                HStack(spacing: 7) {
                    Circle().fill(store.connection == .connected ? .green : .orange).frame(width: 6, height: 6)
                    Text(store.connection.rawValue).font(.caption)
                    Spacer()
                }.foregroundStyle(.secondary).padding(14)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { if $0 > 0 { sidebarWidth = $0 } }
            .navigationSplitViewColumnWidth(min: Self.sidebarMinWidth, ideal: 230, max: Self.sidebarMaxWidth)
    }
    @ViewBuilder private var detail: some View {
            if fixedConversation == nil, store.shortcut == .home {
                HomePane(store: store).safeAreaInset(edge: .top, spacing: 0) { expiredBanner }
            } else if fixedConversation == nil, store.shortcut == .drafts {
                DraftList(store: store).safeAreaInset(edge: .top, spacing: 0) { expiredBanner }
            } else if fixedConversation == nil, let shortcut = store.shortcut {
                ShortcutList(store: store, shortcut: shortcut).safeAreaInset(edge: .top, spacing: 0) { expiredBanner }
            } else if let room {
                // Scroll state belongs to one conversation; the toolbar stays outside so it is not duplicated on switch.
                // The thread and info panel is our own pane: SwiftUI's .inspector inside a NavigationSplitView
                // re-measures its columns without settling on macOS 27 and AppKit aborts the app.
                SidePaneSplit(open: store.info || store.threadID != nil) {
                    VStack(spacing: 0) { TimelineView(store: store, conversation: room).id(room.id) }
                        .safeAreaInset(edge: .top, spacing: 0) { expiredBanner }
                } pane: {
                    Group {
                        if store.info {
                            InfoPanel(store: store, room: room, search: fixedConversation == nil ? { searching = true } : nil)
                        } else if let thread = store.threadID {
                            ThreadPane(store: store, room: room, thread: thread)
                        }
                    }
                    // Esc closes the info panel wherever focus is; the composer's own Esc also closes it.
                    .background { if store.info { Button("") { store.info = false }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true) } }
                }
                    .toolbar {
                        // On the left in the title's place and size, as Home and the other shortcuts show theirs.
                        ToolbarItem(placement: .navigation) {
                            Button { store.toggleInfo() } label: { VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    // The dot first, so it stays in one place whatever the name's length.
                                    if let partner = store.partner(in: room) { PresenceDot(presence: store.presence[partner]) }
                                    Text(room.name).font(.title3.weight(.semibold)).lineLimit(1)
                                }
                                if room.kind != .direct, !room.members.isEmpty { Text("\(room.members.count) members").font(.caption).foregroundStyle(.secondary) }
                                if let partner = store.partner(in: room), let status = store.statuses[partner] {
                                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.contentShape(Rectangle()) }
                            .buttonStyle(.plain).help("Conversation info (⌘I)")
                        }
                        .titleWithoutGlass()
                        if #available(macOS 26, *) { ToolbarSpacer(.flexible) }   // search on the right, the name on the left
                        // Web's call button; a menu, as calls and huddles may join it.
                        ToolbarItem(placement: .primaryAction) {
                            Menu { Button("Send a Meet Link") { sendMeetLink(room.id) } } label: { Image(systemName: "video") }
                                .menuIndicator(.visible).help("Video call")
                        }
                        if fixedConversation == nil {   // results open in the main window, so search lives only there
                            ToolbarItem(placement: .primaryAction) { Button { searching = true } label: { Image(systemName: "magnifyingglass") }.help("Search messages (⇧⌘F)") }
                        }
                    }
                    .focusedSceneValue(\.meetLinkConversation, room.id)
                    .toolbar(removing: .title)   // the conversation's name is the title; the window keeps "Parley" for its menus
                    .safeAreaInset(edge: .top, spacing: 0) { Divider() }   // the line under the header, as Home's
            } else { ContentUnavailableView("Choose a conversation", systemImage: "bubble.left.and.bubble.right", description: Text("Your conversations will appear here."))
                .safeAreaInset(edge: .top, spacing: 0) { expiredBanner } }
    }
    var body: some View {
        Group {
            // A conversation's own window is just that conversation: no split view, so no sidebar or its button.
            if fixedConversation != nil { NavigationStack { detail } }
            // The detail's minimum stops a dragged sidebar from squeezing the timeline and pane off the window's edge.
            else { NavigationSplitView(columnVisibility: $columns) { sidebar } detail: {
                detail.navigationSplitViewColumnWidth(min: Self.minWidth(paneOpen: store.info || store.threadID != nil, sidebar: 0), ideal: 700)
            } }
        }
        .frame(minWidth: Self.minWidth(paneOpen: store.info || store.threadID != nil, sidebar: 0), minHeight: 480)
        .onChange(of: store.info || store.threadID != nil) { _, open in
            if open { Self.makeRoom(Self.widthForPane(window: width, sidebar: Self.shownSidebar(fixedConversation: fixedConversation, columns: columns, measured: sidebarWidth)), in: hostWindow.window) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0; fitSidebar() }
        .background(WindowReader(ref: hostWindow))
        .onChange(of: store.info || store.threadID != nil) { fitSidebar() }
        .onChange(of: columns) { _, shown in
            // Shown by the user in a window too narrow for it: widen the window rather than clip.
            if shown != .detailOnly { sidebarAutoHidden = false; Self.makeRoom(Self.minWidth(paneOpen: store.info || store.threadID != nil, sidebar: sidebarWidth), in: hostWindow.window) }
        }
        .sheet(isPresented: $switcher) { ConversationPalette(store: store) }
        .sheet(isPresented: $composing) { ConversationPalette(store: store, newChat: true) }
        .sheet(item: $store.forwarding) { message in
            ConversationPalette(store: store, then: { store.forward(message, to: $0) })
        }
        .sheet(isPresented: $searching) { FinderPanel(store: store) }
        .onChange(of: store.newChatRequests) { if fixedConversation == nil { composing = true } }
        .background {
            Group {
                Button("") { switcher = true }.keyboardShortcut("k")
                Button("") {   // a composer with text keeps ⌘I for italic
                    if let composer = NSApp.keyWindow?.firstResponder as? ComposerTextView, !composer.string.isEmpty { composer.formatItalic(nil) }
                    else if room != nil { store.toggleInfo() }
                }.keyboardShortcut("i")
                Button("") { searching = true }.keyboardShortcut("f", modifiers: [.command, .shift]).disabled(fixedConversation != nil)
                ForEach(1...9, id: \.self) { number in
                    Button("") { if let room = Conversation.atShortcut(number, in: store.conversations) { Task { await store.select(room.id) } } }
                        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                }
                Button("") { if let room = Conversation.nextUnread(after: store.selectedID, in: store.conversations, forward: true) { Task { await store.select(room.id) } } }
                    .keyboardShortcut(.downArrow, modifiers: .option)
                Button("") { if let room = Conversation.nextUnread(after: store.selectedID, in: store.conversations, forward: false) { Task { await store.select(room.id) } } }
                    .keyboardShortcut(.upArrow, modifiers: .option)
                Button("") {
                    if let room, let last = store.timeline(room.id).last(where: { $0.sender.id == store.me.id }) { store.edit(last) }
                }.keyboardShortcut("e")
            }.hidden()
        }
        .overlay {
            if store.needsSignIn {
                if let signIn { WelcomeView(flow: signIn) }
                else {
                    ContentUnavailableView("Signed out of Google Chat", systemImage: "person.crop.circle.badge.exclamationmark")
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
                }
            }
        }
        .toolbar(store.needsSignIn ? .hidden : .automatic, for: .windowToolbar)
        // A frosted toolbar across the window, over the timeline and the side pane alike, instead of a clear one that
        // content (the wallpaper, a scrolled pane) shows through.
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .confirmationDialog("Leave “\(leaving?.name ?? "")”?", isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } })) {
            Button("Leave", role: .destructive) { if let room = leaving { Task { await store.leave(room.id) } } }
        } message: { Text("It leaves your sidebar. You can be added again later.") }
        .alert("Something went wrong",isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
        .task(id: fixedConversation.flatMap(store.hasConversation)) {
            if let fixedConversation {   // a restored window: loads, or closes when the conversation isn't this account's
                switch store.hasConversation(fixedConversation) {
                case true?: await store.load(fixedConversation)
                case false?: dismissWindow()
                case nil: break
                }
            } else {
                // Not awaited: the permission prompt waits for the user, and until then nothing would connect or ask to sign in.
                if store.notifier != nil, NotificationSettings.current.enabled { Task { await SystemNotifier.requestAuthorization() } }
                await store.start()
            }
        }
        .onChange(of: store.unreadCount) { _, value in NSApplication.shared.dockTile.badgeLabel = value == 0 ? nil : String(value) }
    }
    @ViewBuilder private var expiredBanner: some View {
        if store.sessionExpired, let signIn { SessionExpiredBanner(flow: signIn) }
    }
    /// A shortcut's sidebar row tag; conversation ids never start with it.
    private static func tag(_ shortcut: Shortcut) -> String { "shortcut:" + shortcut.rawValue }
    /// A collapsible section; which ones are collapsed is remembered across launches. Shortcuts lead with Mentions and Starred.
    @ViewBuilder private func section(_ title: String, rooms: [Conversation]) -> some View {
        if !rooms.isEmpty || (title == "Shortcuts" && fixedConversation == nil) {
            Section(title, isExpanded: Binding(get: { !collapsedSections.split(separator: "\n").contains { $0 == title } }, set: { expanded in
                var titles = Set(collapsedSections.split(separator: "\n").map(String.init))
                if expanded { titles.remove(title) } else { titles.insert(title) }
                collapsedSections = titles.sorted().joined(separator: "\n")
            })) {
                if title == "Shortcuts" && fixedConversation == nil {
                    ForEach(Shortcut.allCases, id: \.self) { shortcut in
                        HStack {
                            Label(shortcut.title, systemImage: shortcut.icon).font(.system(size: 13))
                            if shortcut == .drafts, case let count = store.draftList().count, count > 0 {   // as web shows it
                                Spacer(minLength: 0)
                                Text("\(count)").font(.system(size: 11)).foregroundStyle(.secondary).accessibilityLabel("\(count) drafts")
                            }
                        }.tag(Self.tag(shortcut))
                    }
                }
                ForEach(rooms) { room in
                    HStack(spacing: 8) {
                        Avatar(name: room.name, space: room.kind == .space, size: 20, url: room.avatarURL, emoji: room.emoji)
                            .overlay(alignment: .bottomTrailing) {
                                if let partner = store.partner(in: room) { PresenceDot(presence: store.presence[partner], size: 7).offset(x: 2, y: 2) }
                            }
                        Text(room.name).font(.system(size: 13, weight: room.unread > 0 ? .semibold : .regular)).lineLimit(1).truncationMode(.tail).help(room.name)
                        Spacer(minLength: 0)
                        if room.muted { Image(systemName: "bell.slash").font(.caption2).foregroundStyle(.secondary) }
                        if room.unread > 0 { Text("\(room.unread)").font(.system(size: 11, weight: .semibold, design: .rounded)).padding(.horizontal, 6).padding(.vertical, 2).background(.blue, in: Capsule()).foregroundStyle(.white).fixedSize() }
                    }.tag(room.id)
                        .contextMenu {
                            if room.unread > 0 { Button("Mark as read") { Task { await store.markRead(room.id) } } }
                            else { Button("Mark as unread") { Task { await store.markUnread(room.id) } } }
                            Button(room.pinned ? "Unpin" : "Pin") { Task { await store.setPinned(!room.pinned, room.id) } }
                            Button(room.muted ? "Unmute" : "Mute") { Task { await store.setMuted(!room.muted, room.id) } }
                            NotificationLevelPicker(store: store, room: room)
                            Button("Open in new window") { openWindow(value: room.id) }
                            if room.kind != .direct {
                                Divider()
                                Button("Leave…", role: .destructive) { leaving = room }
                            }
                        }
                        .accessibilityElement(children: .ignore).accessibilityLabel("\(room.name), \(room.unread) unread")
                }
            }
        }
    }
}
/// One timeline row with its grouping decided from a single snapshot, so rows never index a list that changed meanwhile.
struct TimelineRow: Identifiable, Hashable {
    let message: Message
    let begins: Bool   // first of a run: same sender, gaps under 5 min
    let ends: Bool     // last of a run
    let newDay: Bool
    var seenBy: [String] = []   // names of readers whose receipt ends at this message
    var draft = false           // a thread's first message whose reply box holds a draft
    var transcriptOpen = false  // its voice message's whole transcript shows, not one line; its card's cut paragraph, all of it; or its original, not Google's translation
    var id: MessageID { message.id }

    static func rows(_ items: [Message], seen: [MessageID: [String]] = [:], drafts: Set<ThreadID> = [], transcripts: Set<MessageID> = []) -> [TimelineRow] {
        items.indices.map { index in
            var message = items[index]
            // A translated message shows its translation until opened ("View original"), which shows the original.
            if let translation = message.translation, !transcripts.contains(message.id) {
                message.text = translation.text; message.formatting = translation.formatting
            }
            let previous = index > 0 ? items[index - 1] : nil
            let next = index + 1 < items.count ? items[index + 1] : nil
            return TimelineRow(
                message: message,
                begins: previous.map { $0.isSystem || $0.sender.id != message.sender.id || message.createdAt.timeIntervalSince($0.createdAt) >= 300 } ?? true,
                ends: next.map { $0.isSystem || $0.sender.id != message.sender.id || $0.createdAt.timeIntervalSince(message.createdAt) >= 300 } ?? true,
                newDay: previous.map { !Calendar.current.isDate($0.createdAt, inSameDayAs: message.createdAt) } ?? true,
                seenBy: seen[message.id] ?? [], draft: drafts.contains(message.id), transcriptOpen: transcripts.contains(message.id))
        }
    }
}

struct TimelineView: View {
    @Bindable var store: ChatStore
    let conversation: Conversation
    var thread: String? = nil
    var detached = false   // a thread in its own window
    @State private var atBottom = true
    @State private var arrivedAway = 0   // new messages while scrolled up: the scroll-to-bottom badge
    @State private var scrollRequest = 0
    @AppStorage("timelineStyle") private var style = TimelineStyle.bubbles
    @AppStorage(Wallpaper.key(dark: false)) private var wallpaper = Wallpaper.none
    @AppStorage(Wallpaper.key(dark: true)) private var darkWallpaper = Wallpaper.none
    @AppStorage(BubblePalette.colorKey(dark: false)) private var bubbleColor = ""
    @AppStorage(BubblePalette.colorKey(dark: true)) private var darkBubbleColor = ""
    @AppStorage(Wallpaper.doodlesKey) private var doodles = true
    @State private var composerHeight: CGFloat = 0   // the floating composer's height: the timeline's bottom inset
    private var items: [Message] { store.timeline(conversation.id, thread: thread) }
    private var actions: MessageRowActions {
        MessageRowActions(react: { emoji, message in Task { await store.react(emoji, to: message) } },
                          toggleTranscript: { store.toggleTranscript($0.id) },
                          dismissCard: { store.dismissCard(of: $0) },
                          clickCard: { message, action, inputs in await store.clickCard(message, action: action, inputs: inputs) },
                          reactCustom: { emoji, message in Task { await store.react(emoji.text, custom: emoji, to: message) } },
                          customEmoji: { await store.loadCustomEmoji(); return store.customEmoji },
                          reactors: { reaction, message in await store.reactorsLine(reaction, on: message.id) },
                          openThread: { message in Task { await store.openThread(message) } },
                          quote: { store.quote($0) },
                          forward: { store.forwarding = $0 },
                          // A forward's message lives in the conversation it came from: open it there.
                          showQuoted: { id in Task {
                              if !id.hasPrefix(conversation.id + "/"), let url = ChatLink.url(message: id), let link = ChatLink(url) { _ = await store.open(link) }
                              else { await store.showQuoted(id, in: conversation.id) }
                          } },
                          message: { person in Task { do { try await store.message([person]) } catch { store.report(error) } } },
                          person: { store.person($0, in: conversation.id) },
                          openChatLink: { link, _ in await store.open(link) },
                          retry: { message in Task { await store.retry(message) } },
                          edit: { store.edit($0) },
                          delete: { message in Task { await store.delete(message) } },
                          star: { starred, message in Task { await store.setStarred(starred, message) } },
                          readers: { [conversation] message in
                              conversation.kind == .space ? [] : store.readers(of: message).map { store.name(of: $0, in: conversation.id) }
                          },
                          loadAttachment: { attachment, thumbnail in try await store.attachmentData(attachment, thumbnail: thumbnail) },
                          emojiUsage: EmojiUsage())
    }
    /// Receipts show in the conversation's own timeline, not in a thread.
    private var rows: [TimelineRow] {
        let seen = thread == nil ? store.seen(in: conversation).mapValues { $0.map { store.name(of: $0, in: conversation.id) } } : [:]
        return TimelineRow.rows(items, seen: seen, drafts: thread == nil ? store.threadsWithDrafts(in: conversation.id) : [], transcripts: store.openTranscripts)
    }
    var body: some View {
        // The composer floats over the timeline, which scrolls under it with a bottom inset of the composer's height.
        Group {
            if items.isEmpty {
                ContentUnavailableView("Start the conversation", systemImage: "bubble.left", description: Text("Send a message below."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, composerHeight)   // full width: the composer spans it
            } else {
                MessageTable(rows: rows, meID: store.me.id, kind: conversation.kind, style: style, look: [wallpaper.rawValue, darkWallpaper.rawValue, bubbleColor, darkBubbleColor].joined(separator: "/"), highlighted: store.highlightedID,
                             identifier: thread == nil ? "timeline" : "thread", actions: actions,
                             nearTop: { Task { await store.loadOlderIfNeeded(conversation.id, thread: thread) } },
                             atBottomChanged: { atBottom = $0; if $0 { arrivedAway = 0 } }, scrollRequest: scrollRequest,
                             bottomInset: composerHeight)
            }
        }
        .background { WallpaperView(doodles: doodles) }
        .overlay(alignment: .top) {
            if store.loading.contains(store.key(conversation.id, thread)) && !items.isEmpty {
                ProgressView().controlSize(.small).padding(8)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !atBottom && !items.isEmpty {
                Button { scrollRequest += 1 } label: {
                    Image(systemName: "chevron.down").font(.system(size: 15, weight: .semibold)).frame(width: 38, height: 38)
                        .floatingGlass(Circle(), interactive: true)
                        .overlay(alignment: .top) {
                            if arrivedAway > 0 {
                                Text("\(arrivedAway)").font(.caption2.bold()).foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.accentColor, in: Capsule()).offset(y: -8)
                            }
                        }
                }.buttonStyle(.plain).padding(16).padding(.bottom, composerHeight)
                    .help("Scroll to the newest message").accessibilityLabel("Scroll to the newest message")
            }
        }
        .overlay(alignment: .bottom) {
            // Its own view, so typing and the composer's own state update only the composer, not the timeline.
            ComposerBar(store: store, conversation: conversation, thread: thread, detached: detached)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
        }
        .onChange(of: items.last?.id) { _, _ in if !atBottom { arrivedAway += 1 } }
        .dropDestination(for: URL.self) { urls, _ in   // files dropped anywhere on the conversation join the draft
            let files = urls.filter(\.isFileURL)
            store.attach(files, conversation: conversation.id, thread: thread)
            return !files.isEmpty
        }
    }
}

/// The floating composer under a timeline. Its own view so its state (the draft, the pickers, the typing line) updates
/// only it: inside the timeline view, every keystroke re-ran the timeline's update.
struct ComposerBar: View {
    @Bindable var store: ChatStore
    let conversation: Conversation
    var thread: String? = nil
    var detached = false   // a thread in its own window
    @State private var formatBar = false   // the composer's formatting row
    @State private var gifPicker = false
    @State private var emojiPicker = false
    @State private var composerHandle = ComposerHandle()
    @State private var linking: LinkForm.Draft?   // the link form, with the selection it started from
    @State private var colorPicker = false
    @State private var recorder = VoiceRecorder()
    private var typingLine: String? {
        store.activityLine(conversation.id, thread: thread)
            ?? ChatStore.typingLine(store.typists(conversation.id, thread: thread).map { store.name(of: $0, in: conversation.id) })
    }
    var body: some View {
        composer
            .onChange(of: conversation.id) { recorder.cancel() }   // a recording belongs to the conversation it started in
            .onDisappear { recorder.cancel() }
            .onAppear { composerHandle.askForLink = { linking = LinkForm.Draft(text: composerHandle.selectedText) } }
            .sheet(item: $linking) { draft in
                LinkForm(draft: draft) { url, text in composerHandle.link(url, text: text) }
            }
    }
    private func formatButton(_ icon: String, _ help: String, _ action: Selector) -> some View {
        Button { NSApp.sendAction(action, to: nil, from: nil) } label: { Image(systemName: icon).frame(width: 26, height: 22) }
            .buttonStyle(.borderless).help(help).accessibilityLabel(help)
    }
    private var scope: String { store.key(conversation.id, thread) }
    private var pendingFiles: [Attachment] { store.draftAttachments[scope] ?? [] }
    private func attach(_ urls: [URL]) { store.attach(urls, conversation: conversation.id, thread: thread) }
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        panel.begin { response in if response == .OK { attach(panel.urls) } }
    }
    /// A pending attachment above the field: a thumbnail for images, the file's icon otherwise, and a remove button.
    private func chip(_ file: Attachment) -> some View {
        HStack(spacing: 6) {
            let path = file.url?.path(percentEncoded: false) ?? ""
            Image(nsImage: file.kind == .image ? NSImage(contentsOfFile: path) ?? NSWorkspace.shared.icon(forFile: path) : NSWorkspace.shared.icon(forFile: path))
                .resizable().scaledToFill().frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 5))
            Text(file.name).font(.caption).lineLimit(1).truncationMode(.middle).frame(maxWidth: 140, alignment: .leading)
            Button { store.detach(file, conversation: conversation.id, thread: thread) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("Remove").accessibilityLabel("Remove \(file.name)")
        }
        .padding(4).padding(.trailing, 4)
        .floatingGlass(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    private var draft: String { store.drafts[scope] ?? "" }
    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingFiles.isEmpty || store.quoting[scope]?.forwardedFrom != nil }
    /// Floating glass pieces over the timeline, as Telegram lays them out: a round attach button, the field (with
    /// Aa, emoji and GIF at its end) and a round send button; the edit, reply, formatting, upload and typing rows
    /// float as small capsules above the field.
    private var composer: some View {
        FloatingGlassGroup {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let typingLine {
                        Text(typingLine).font(.caption).foregroundStyle(.secondary).lineLimit(1).floatingCapsule()
                    }
                    if formatBar {
                        // Web's toolbar, in its order; the field's ComposerTextView is first responder and takes the actions.
                        HStack(spacing: 2) {
                            formatButton("bold", "Bold (⌘B)", #selector(ComposerTextView.formatBold(_:)))
                            formatButton("italic", "Italic (⌘I)", #selector(ComposerTextView.formatItalic(_:)))
                            formatButton("underline", "Underline (⌘U)", #selector(ComposerTextView.formatUnderline(_:)))
                            // Web's colour button: an "A" underlined in the current colour, opening a row of dots.
                            Button { colorPicker.toggle() } label: {
                                Image(systemName: "character").overlay(alignment: .bottom) {
                                    Capsule().fill(composerHandle.view?.currentColor.map { Color(nsColor: NSColor(rgb: $0.argb & 0xFF_FFFF)) } ?? .secondary)
                                        .frame(width: 13, height: 2.5).offset(y: 3)
                                }.frame(width: 26, height: 22)
                            }
                            .buttonStyle(.borderless).help("Text color").accessibilityLabel("Text color")
                            .popover(isPresented: $colorPicker, arrowEdge: .top) {
                                ColorDots(current: composerHandle.view?.currentColor) { color in
                                    composerHandle.view?.color(color); colorPicker = false
                                    if let view = composerHandle.view { view.window?.makeFirstResponder(view) }
                                }
                            }
                            formatButton("strikethrough", "Strikethrough (⇧⌘X)", #selector(ComposerTextView.formatStrike(_:)))
                            Divider().frame(height: 16)
                            formatButton("list.bullet", "Bulleted list (⇧⌘8)", #selector(ComposerTextView.formatList(_:)))
                            Divider().frame(height: 16)
                            formatButton("text.quote", "Quote (⇧⌘I)", #selector(ComposerTextView.formatQuote(_:)))
                            formatButton("link", "Link (⌘K)", #selector(ComposerTextView.formatLink(_:)))
                            Divider().frame(height: 16)
                            formatButton("chevron.left.forwardslash.chevron.right", "Code (⇧⌘C)", #selector(ComposerTextView.formatCode(_:)))
                            formatButton("curlybraces.square", "Code block (⌥⇧⌘C)", #selector(ComposerTextView.formatCodeBlock(_:)))
                        }.padding(.horizontal, -6).floatingCapsule()
                    }
                    if store.uploading(conversation.id, thread: thread) > 0 {
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Uploading…").font(.caption).foregroundStyle(.secondary) }.floatingCapsule()
                    }
                    if !pendingFiles.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) { ForEach(pendingFiles, id: \.self) { chip($0) } }.padding(4)
                        }
                    }
                }.padding(.leading, Self.control + 8)   // above the field, not the attach button
                HStack(alignment: .bottom, spacing: 8) {
                    if recorder.isRecording {   // Telegram's recording bar: ✕ cancels (Esc), the round button sends (Return)
                        Button { recorder.cancel() } label: {
                            Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.secondary)
                                .frame(width: Self.control, height: Self.control).floatingGlass(Circle(), interactive: true)
                        }.buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Cancel recording (Esc)").accessibilityLabel("Cancel recording")
                        RecordingBar(recorder: recorder).frame(maxWidth: .infinity, minHeight: Self.control)
                            .floatingGlass(RoundedRectangle(cornerRadius: Self.control / 2, style: .continuous))
                        Button(action: sendRecording) {
                            Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: Self.control, height: Self.control).floatingGlass(Circle(), tint: .accentColor, interactive: true)
                        }.buttonStyle(.plain).keyboardShortcut(.defaultAction).help("Send voice message (Return)").accessibilityLabel("Send voice message")
                    } else {
                        Button(action: chooseFiles) {
                            Image(systemName: "paperclip").font(.system(size: 17)).foregroundStyle(.secondary)
                                .frame(width: Self.control, height: Self.control).floatingGlass(Circle(), interactive: true)
                        }.buttonStyle(.plain).help("Attach files").accessibilityLabel("Attach files")
                        field
                        if canSend || store.editingID(conversation.id, thread: thread) != nil {
                            Button { Task { await store.send(conversation: conversation.id, thread: thread) } } label: {
                                Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold)).foregroundStyle(canSend ? .white : .secondary)
                                    .frame(width: Self.control, height: Self.control)
                                    .floatingGlass(Circle(), tint: canSend ? .accentColor : nil, interactive: true)
                            }.buttonStyle(.plain).disabled(!canSend).help("Send message").accessibilityLabel("Send message")
                        } else {   // an empty field offers a voice message instead, as Telegram does
                            Button { Task { do { try await recorder.start() } catch { store.report(error) } } } label: {
                                Image(systemName: "mic").font(.system(size: 17)).foregroundStyle(.secondary)
                                    .frame(width: Self.control, height: Self.control).floatingGlass(Circle(), interactive: true)
                            }.buttonStyle(.plain).help("Record voice message").accessibilityLabel("Record voice message")
                        }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 12)
        }
    }
    /// Ends this composer's edit and clears the message's text from it.
    private func endEdit() { store.editing[scope] = nil; store.setDraft("", conversation: conversation.id, thread: thread) }
    private func sendRecording() {
        guard let recording = recorder.finish() else { return }
        Task { await store.sendVoice(recording.file, duration: recording.duration, waveform: recording.levels, conversation: conversation.id, thread: thread) }
    }
    private static let control: CGFloat = 42   // round buttons, and the field's height on one line
    @State private var fieldHeight: CGFloat = 0   // the text view's laid-out height; wrapped paragraphs count, not only newlines
    /// The text capsule: the native field, a placeholder while empty, and Aa, emoji and GIF at its end.
    private var field: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let editing = store.editingID(conversation.id, thread: thread).flatMap({ id in store.messages.first { $0.id == id } }) { editHeader(editing) }
            else if let quote = store.quoting[scope] { quoteHeader(quote) }
            fieldRow
        }
        .floatingGlass(RoundedRectangle(cornerRadius: Self.control / 2, style: .continuous))
        .help("Return to send · Shift-Return for a new line · Paste or drop files to attach")
    }
    /// The reply or forward inside the field, as Telegram shows it: an accent bar, who, and one line of the message.
    private func quoteHeader(_ quote: QuotedMessage) -> some View {
        accessoryHeader(title: quote.forwardedFrom == nil ? "Reply to \(quote.sender)" : "Forward from \(quote.sender)", text: quote.text, media: quote.media,
                        closeHelp: quote.forwardedFrom == nil ? "Cancel reply" : "Cancel forward", close: { store.quoting[scope] = nil }) {
            guard let id = quote.id else { return }
            Task {
                if !id.hasPrefix(conversation.id + "/"), let url = ChatLink.url(message: id), let link = ChatLink(url) { _ = await store.open(link) }
                else { await store.showQuoted(id, in: conversation.id) }
            }
        }
    }
    /// Telegram's edit panel: the message being edited, one line; its attachments stay, as in Google Chat.
    private func editHeader(_ message: Message) -> some View {
        accessoryHeader(title: "Edit message", text: QuotedMessage.summary(text: TextStyleRange.plain(message.text, message.formatting), attachments: message.attachments),
                        media: message.attachments.first { $0.kind == .image || $0.kind == .video }, closeHelp: "Cancel editing",
                        close: endEdit) {
            Task { await store.showQuoted(message.id, in: conversation.id) }
        }
    }
    private func accessoryHeader(title: String, text: String, media: Attachment?, closeHelp: String, close: @escaping () -> Void, show: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1, style: .continuous).fill(Color.accentColor).frame(width: 3)
            if let media {
                Thumbnail(attachment: media, load: { try await store.attachmentData($0, thumbnail: $1) }).frame(width: 34, height: 34)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium)).foregroundStyle(Color.accentColor).lineLimit(1)
                Text(text).font(.callout).lineLimit(1).truncationMode(.tail)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: show)   // as in Telegram, a click shows the message
            .help("Show the message")
            Spacer(minLength: 0)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("\(closeHelp) (Esc)").accessibilityLabel(closeHelp)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 14).padding(.trailing, 16).padding(.top, 10)
    }
    private var fieldRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            NativeComposer(text: draft, formatting: store.draftFormatting[scope] ?? [],
                           change: { text, formatting in
                               store.setDraft(text, formatting: formatting, conversation: conversation.id, thread: thread)
                               Task { await store.typed(text, conversation: conversation.id, thread: thread) }
                           }, send: { Task { await store.send(conversation: conversation.id, thread: thread) } }, editLast: {
                if let last = store.timeline(conversation.id, thread: thread).last(where: { $0.sender.id == store.me.id }) { store.edit(last) }
            }, cancel: {   // Esc: drops the quote first, then ends an edit and closes the thread
                if store.quoting[scope] != nil { store.quoting[scope] = nil }
                else if store.editing[scope] != nil { endEdit() }
                else if !detached { store.threadID = nil; store.info = false }   // a thread window leaves the main window's panes alone
            }, attach: attach,
               members: store.mentionCandidates(conversation.id), spaces: store.conversations, needMembers: { Task { await store.loadMembers(conversation.id) } },
               customEmoji: store.customEmoji, needCustomEmoji: { Task { await store.loadCustomEmoji() } },
               loadImage: { try await store.attachmentData($0, thumbnail: $1) },
               focus: store.quoting[scope]?.id, handle: composerHandle, height: { if fieldHeight != $0 { fieldHeight = $0 } })
            .frame(minWidth: 60).frame(height: min(130, max(Self.control, fieldHeight)))
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {   // aligned with the text view's inset and line padding
                    Text("Message").foregroundStyle(.tertiary).padding(.leading, 13).padding(.top, 11).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            Button { formatBar.toggle() } label: { Text("Aa").font(.system(size: 14, weight: .semibold)).fixedSize().foregroundStyle(formatBar ? Color.accentColor : .secondary) }
                .buttonStyle(.plain).padding(.bottom, 13).help(formatBar ? "Hide formatting" : "Show formatting").accessibilityLabel("Formatting")
            Button { emojiPicker.toggle() } label: { Image(systemName: "face.smiling").font(.system(size: 18)).foregroundStyle(emojiPicker ? Color.accentColor : .secondary) }
                .buttonStyle(.plain).padding(.bottom, 11).help("Emoji").accessibilityLabel("Emoji")
                .popover(isPresented: $emojiPicker, arrowEdge: .top) { composerHandle.emojiPicker(custom: { await store.loadCustomEmoji(); return store.customEmoji },
                                                                                       loadImage: { try await store.attachmentData($0, thumbnail: $1) },
                                                                                       close: { emojiPicker = false }) }
            Button { gifPicker.toggle() } label: { Text("GIF").font(.system(size: 11, weight: .bold)).fixedSize().padding(.horizontal, 3).overlay(RoundedRectangle(cornerRadius: 3).stroke(lineWidth: 1.5)).foregroundStyle(gifPicker ? Color.accentColor : .secondary) }
                .buttonStyle(.plain).padding(.bottom, 14).help("GIF").accessibilityLabel("GIF")
                .popover(isPresented: $gifPicker, arrowEdge: .top) {
                    GifPicker(pick: { gif in Task { await store.sendGif(gif, conversation: conversation.id, thread: thread) } }, close: { gifPicker = false })
                }
        }
        .padding(.trailing, 14)
    }}

/// On macOS 26 the floating pieces are Liquid Glass and blend when close; earlier, material shapes.
/// The thread pane: the thread's first message over its replies and composer, beside a conversation or Home.
struct ThreadPane: View {
    @Bindable var store: ChatStore
    let room: Conversation
    let thread: ThreadID
    var detached = false   // in its own window, which has its own close button
    @Environment(\.openWindow) private var openWindow
    @State private var parentExpanded = false   // the first message beyond its first four lines
    @State private var emojiLoads = 0   // custom emoji pictures arrived: the header redraws
    var body: some View {
        VStack(spacing: 0) {
            if !detached {
                HStack(spacing: 12) {
                    Text("Thread").font(.headline); Spacer()
                    Button { if let ref = store.detachThread(in: room.id) { openWindow(value: ref) } } label: { Image(systemName: "macwindow.badge.plus") }
                        .buttonStyle(.plain).help("Open in new window")
                    Button { store.threadID = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close")
                }.padding()
                Divider()
            }
            if let parent = store.messages.first(where: { $0.id == thread }) {
                // A long first message would push the replies out of the pane: four lines, a click shows the rest.
                VStack(alignment: .leading) {
                    Text(parent.sender.name).font(.caption).foregroundStyle(.secondary)
                    // The timeline's own text: formatting, mentions, links and custom emoji as in the bubble.
                    NativeMessageText(text: parent.text, formatting: parent.formatting, own: false, lines: parentExpanded ? 0 : 4,
                                      maxWidth: .infinity, redraw: emojiLoads)
                        .task(id: parent.id) { await loadEmoji(in: parent) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding()
                .contentShape(Rectangle()).onTapGesture { parentExpanded.toggle() }
                .help(parentExpanded ? "Show less" : "Show the whole message")
                .onChange(of: thread) { parentExpanded = false }
                Divider()
            }
            TimelineView(store: store, conversation: room, thread: thread, detached: detached).id(thread)
        }
    }
    /// Its custom emoji's pictures, which the text draws from `ImageCache` once they are there.
    private func loadEmoji(in message: Message) async {
        for range in message.formatting {
            guard case .customEmoji(let emoji) = range.style, !emoji.deleted, let picture = emoji.image, ImageCache.cached(picture) == nil else { continue }
            if (try? await ImageCache.load(picture, store.attachmentData)) != nil { emojiLoads += 1 }
        }
    }
}

/// Web's text colour picker: the default colour, then its five, the current one checked.
struct ColorDots: View {
    let current: TextColor?
    let pick: (TextColor?) -> Void
    var body: some View {
        HStack(spacing: 10) {
            ForEach([nil] + TextColor.allCases.map(Optional.some), id: \.self) { (color: TextColor?) in
                Button { pick(color) } label: {
                    Circle().fill(color.map { Color(nsColor: NSColor(rgb: $0.argb & 0xFF_FFFF)) } ?? Color(nsColor: .textColor))
                        .overlay { if color == current { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(Self.check(on: color)) } }
                        .overlay(Circle().stroke(.quaternary))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain).help(color?.name ?? "Default").accessibilityLabel(color?.name ?? "Default color")
            }
        }
        .padding(12)
    }
    /// A checkmark that shows on its dot: the default dot is the text colour (dark or light), amber is light.
    private static func check(on color: TextColor?) -> Color {
        switch color { case nil: Color(nsColor: .textBackgroundColor); case .amber?: .black; default: .white }
    }
}

/// Add Link, as Mail's ⌘K asks: the text (the selection, if any) and the address.
struct LinkForm: View {
    struct Draft: Identifiable { let id = UUID(); var text: String }
    let draft: Draft
    let add: (URL, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var address = ""
    /// The address as typed, with https:// when it has no scheme ("example.com").
    nonisolated static func url(_ address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let full = trimmed.contains("://") || trimmed.hasPrefix("mailto:") ? trimmed : "https://" + trimmed
        return URL(string: full).flatMap { $0.host() != nil || $0.scheme == "mailto" ? $0 : nil }
    }
    var body: some View {
        Form {
            TextField("Text", text: $text, prompt: Text("Shown in the message"))
            TextField("Link", text: $address, prompt: Text("https://"))
        }
        .padding(20).frame(width: 380)
        .onAppear { text = draft.text; if Self.url(draft.text) != nil, draft.text.contains(".") { address = draft.text } }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add Link") { if let url = Self.url(address) { add(url, text); dismiss() } }.disabled(Self.url(address) == nil)
            }
        }
    }
}

extension FocusedValues {
    /// The focused window's conversation, for File ▸ Send a Meet Link.
    @Entry var meetLinkConversation: ConversationID?
}

/// File ▸ Send a Meet Link (⇧⌘M), for the conversation in the focused window.
struct MeetLinkMenuItem: View {
    let store: ChatStore
    @FocusedValue(\.meetLinkConversation) private var conversation
    @Environment(\.openURL) private var openURL
    var body: some View {
        Button("Send a Meet Link") {
            guard let conversation else { return }
            Task { if let url = await store.sendMeetLink(in: conversation) { openURL(url) } }
        }
        .keyboardShortcut("m", modifiers: [.command, .shift]).disabled(conversation == nil)
    }
}

/// A thread popped out of the pane: its first message and replies with their composer, as the pane shows them.
struct ThreadWindow: View {
    @Bindable var store: ChatStore
    let ref: ThreadRef
    var body: some View {
        Group {
            if let room = store.conversations.first(where: { $0.id == ref.conversation }) {
                ThreadPane(store: store, room: room, thread: ref.thread, detached: true).navigationTitle("Thread").navigationSubtitle(room.name)
            } else { ProgressView().navigationTitle("Thread") }
        }
        .frame(minWidth: ChatView.paneWidth, minHeight: 400)
        // A restored window loads its thread, or closes when the conversation isn't this account's.
        .task(id: store.hasConversation(ref.conversation)) {
            switch store.hasConversation(ref.conversation) {
            case true?: await store.load(ref.conversation, thread: ref.thread)
            case false?: dismissWindow()
            case nil: break
            }
        }
    }
    @Environment(\.dismissWindow) private var dismissWindow
}

/// Home's list, with a thread row's thread open in the thread pane to its right.
struct HomePane: View {
    @Bindable var store: ChatStore
    var body: some View {
        SidePaneSplit(open: store.threadID != nil && store.selected != nil) {
            ShortcutList(store: store, shortcut: .home)
        } pane: {
            if let thread = store.threadID, let room = store.selected { ThreadPane(store: store, room: room, thread: thread) }
        }
    }
}

/// A timeline (or list) with the thread or info pane to its right, as wide as the user dragged its divider: from
/// `paneWidth` to `paneMaxWidth`, and never so wide the timeline gets less than its minimum. The width is remembered.
struct SidePaneSplit<Main: View, Pane: View>: View {
    var open: Bool
    @ViewBuilder var main: Main
    @ViewBuilder var pane: Pane
    @AppStorage("sidePaneWidth") private var wanted: Double = ChatView.paneWidth
    @State private var room: CGFloat = 0   // this view's width, the timeline's and the pane's together
    @State private var dragStart: CGFloat?
    /// The pane's width: as wanted, within its bounds and what `room` leaves beside the timeline's minimum.
    static func shown(wanted: CGFloat, room: CGFloat) -> CGFloat {
        let most = min(ChatView.paneMaxWidth, max(ChatView.paneWidth, room - ChatView.timelineMinWidth - 1))
        return min(max(wanted, ChatView.paneWidth), most)
    }
    var body: some View {
        let width = Self.shown(wanted: wanted, room: room)
        HStack(spacing: 0) {
            main.frame(minWidth: ChatView.timelineMinWidth, maxWidth: .infinity)
            if open {
                Divider().overlay {
                    // A wider grip than the line, as a split view's divider has.
                    Color.clear.frame(width: 7).contentShape(Rectangle()).pointerStyle(.columnResize)
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = dragStart ?? width
                                dragStart = start
                                wanted = Self.shown(wanted: start - drag.translation.width, room: room)
                            }
                            .onEnded { _ in dragStart = nil })
                }.zIndex(1)
                pane.frame(width: width)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room = $0 }
    }
}

struct FloatingGlassGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: 8) { content } } else { content }
    }
}
extension View {
    @ViewBuilder func floatingGlass(_ shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background { shape.fill(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.regularMaterial)) }
                .overlay(shape.stroke(.quaternary)).shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        }
    }
    /// A small floating row above the composer's field.
    func floatingCapsule() -> some View {
        padding(.horizontal, 12).padding(.vertical, 6).floatingGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
/// ⇧⌘F: message search.
struct FinderPanel: View {
    @Bindable var store: ChatStore
    @State private var query = ""
    @State private var selected: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            TextField("Search messages", text: $query).textFieldStyle(.plain).font(.title3).padding(18).onSubmit { choose() }
            Divider()
            List(selection: $selected) {
                ForEach(store.searchResults) { message in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(message.sender.name) · \(store.conversations.first { $0.id == message.conversationID }?.name ?? "Conversation")").font(.caption).foregroundStyle(.secondary)
                        Text(message.text).lineLimit(3)
                    }.padding(.vertical, 5).tag(message.id).onTapGesture { selected = message.id; choose() }
                }
            }.frame(height: 280)
            HStack { Text("Searches Google Chat").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction); Button("Open") { choose() }.keyboardShortcut(.defaultAction) }.padding(12)
        }.frame(width: 500)
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(250))   // one request per pause in typing, not per keystroke
                guard !Task.isCancelled else { return }
                await store.search(query); selected = store.searchResults.first?.id
            }
    }
    private func choose() {
        guard let selected else { return }
        Task {
            if let message = store.searchResults.first(where: { $0.id == selected }) { await store.jump(message) }
            dismiss()
        }
    }
}

extension ToolbarContent {
    /// A title is not a control: no glass capsule around it (macOS 26 gives every toolbar item one), as Messages shows the name.
    @ToolbarContentBuilder func titleWithoutGlass() -> some ToolbarContent {
        if #available(macOS 26, *) { sharedBackgroundVisibility(.hidden) } else { self }
    }
}

/// The window a view is in, held weakly.
final class WindowRef { weak var window: NSWindow? }
/// Records its view's window in `ref` once it is in one.
private struct WindowReader: NSViewRepresentable {
    let ref: WindowRef
    func makeNSView(context: Context) -> NSView { Reader(ref: ref) }
    func updateNSView(_ view: NSView, context: Context) {}
    final class Reader: NSView {
        let ref: WindowRef
        init(ref: WindowRef) { self.ref = ref; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); ref.window = window }
    }
}
