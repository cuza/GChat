import SwiftUI

@main
struct ParleyApp: App {
    // The test host launches this app; keep it off the network and away from the real cache.
    // UI tests launch it with -uiTestingLongHistory: a long, paged fake history for scroll tests;
    // -uiTestingManyConversations: 320 more conversations, for sidebar tests.
    // -uiTestingDemo: the demo workspace (README screenshots), with -uiTestingDark for dark mode.
    @State private var store: ChatStore
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var signIn: SignInFlow
    private let authorizer: WebSessionAuthorizer
    private let webSignIn: WebViewSignIn
    private let updates: Updates
    init() {
        AppearanceMode.apply()
        let authorizer = WebSessionAuthorizer()
        self.authorizer = authorizer
        let store: ChatStore
        var live = false
        // Tests and the demo workspaces keep no pictures on disk: they'd share the Debug build's folder.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-uiTesting") }) { ImageCache.directory = nil }
        if ProcessInfo.processInfo.arguments.contains("-uiTestingLongHistory") {
            store = ChatStore(backend: FakeBackend(longHistory: 600, latency: .milliseconds(300)))
        } else if ProcessInfo.processInfo.arguments.contains("-uiTestingFormattedThread") {
            store = ChatStore(backend: FakeBackend(formattedThread: true))
        } else if ProcessInfo.processInfo.arguments.contains("-uiTestingManyConversations") {
            UserDefaults.standard.removeObject(forKey: "collapsedSidebarSections")
            store = ChatStore(backend: FakeBackend(manyConversations: 320))
        } else if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || ProcessInfo.processInfo.arguments.contains("-uiTestingDemo") {
            store = ChatStore(backend: FakeBackend())
            RemoteImage.preload(FakeBackend.demoIcons)
            if ProcessInfo.processInfo.arguments.contains("-uiTestingDemo") {   // the README shots don't follow the Mac's appearance
                NSApplication.shared.appearance = NSAppearance(named: ProcessInfo.processInfo.arguments.contains("-uiTestingDark") ? .darkAqua : .aqua)
            }
        } else {
            live = true
            store = ChatStore(backend: DynamiteBackend(authorizer: authorizer), cache: .dynamite)
            store.shortcut = .home   // Google Chat opens on Home; the UI-testing workspaces keep opening a conversation
            _ = SystemNotifier(store: store)   // the store keeps it; registering now catches the click that launched the app
        }
        _store = State(initialValue: store)
        let webSignIn = WebViewSignIn()
        self.webSignIn = webSignIn
        let signIn = SignInFlow(browser: webSignIn, importer: authorizer)
        signIn.onSignedIn = {
            NSApplication.shared.activate()
            await store.start()
        }
        if live {
            // Keep the session alive as the Chat website does: renew it silently when Google ends it, and every few hours.
            signIn.renewer = SessionRenewer()
            store.onSessionLost = { if await signIn.renewSilently() { await store.start() } }
            Task { @MainActor in
                while true {
                    try? await Task.sleep(for: .seconds(6 * 3600))
                    if store.connection == .connected { _ = await signIn.renewSilently() }
                }
            }
        }
        _signIn = State(initialValue: signIn)
        // A mouse's side buttons (3 back, 4 forward) walk the Go menu's history, as they do in Safari and Finder.
        NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            guard let forward = [3: false, 4: true][event.buttonNumber] else { return event }
            Task { forward ? await store.goForward() : await store.goBack() }
            return nil
        }
        // Since macOS 13 tables estimate unmeasured row heights, which moves rows when older pages land above;
        // MessageTable caches real heights, so opt out as Apple's AppKit release notes describe.
        UserDefaults.standard.set(false, forKey: "NSTableViewCanEstimateRowHeights")
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        updates = Updates(start: Updates.shouldStart(live: live, debug: debug))
    }
    var body: some Scene {
        Window("Parley", id: "main") {
            ChatView(store: store)
                .environment(signIn)
                .modifier(WebSignInPresenter(flow: signIn, web: webSignIn))
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in signIn.cancel(); store.flush() }
                // Leaving the composer, as Google Chat's web client saves its draft when you click away.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in store.saveDrafts() }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in store.saveDrafts() }
                .onAppear { appDelegate.beforeQuit = { store.saveDrafts() } }
        }
            .defaultSize(width: 1000, height: 650)
            .commands {
                SidebarCommands()   // View ▸ Show/Hide Sidebar (⌃⌘S): the sidebar can always come back, whatever the toolbar shows
                CommandGroup(after: .appInfo) { CheckForUpdatesItem(updates: updates) }
                CommandGroup(replacing: .newItem) {
                    Button("New Chat") { store.newChatRequests += 1 }.keyboardShortcut("n")
                    MeetLinkMenuItem(store: store)
                }
                CommandGroup(replacing: .help) { DiagnosticsMenuItem() }
                CommandMenu("Go") {
                    Button("Back") { Task { await store.goBack() } }.keyboardShortcut("[").disabled(!store.canGoBack)
                    Button("Forward") { Task { await store.goForward() } }.keyboardShortcut("]").disabled(!store.canGoForward)
                }
            }
        WindowGroup(for: ConversationID.self) { $id in
            if let id = id { ChatView(store: store, fixedConversation: id).environment(signIn) }
        }
        WindowGroup(for: ThreadRef.self) { $ref in
            if let ref { ThreadWindow(store: store, ref: ref).environment(signIn) }
        }
            .defaultSize(width: 420, height: 640)
        Settings { SettingsView(store: store).environment(signIn) }
        // Opened from Settings ▸ Advanced and Help ▸ Report a Problem, not the Window menu.
        Window("Connection Diagnostics", id: "connection-diagnostics") {
            ConnectionDiagnosticsView(store: store, authorizer: authorizer).environment(signIn)
        }
            .defaultSize(width: 560, height: 720)
            .commandsRemoved()
    }
}

/// Help ▸ Report a Problem…: the diagnostics window, whose Save Log… makes the file to send.
private struct DiagnosticsMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Report a Problem…") { openWindow(id: "connection-diagnostics") }
        Button("Export Unsupported Message Shapes…") { MessageShapes.saveExport() }
    }
}


/// Quitting waits (up to 3 s) for the drafts to reach Google; unsaved ones are also kept for the next launch.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var beforeQuit: (() -> Task<Void, Never>)?
    private var replied = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let save = beforeQuit?() else { return .terminateNow }
        replied = false
        Task { await save.value; reply(sender) }
        Task { try? await Task.sleep(for: .seconds(3)); reply(sender) }
        return .terminateLater
    }
    private func reply(_ app: NSApplication) {
        guard !replied else { return }
        replied = true
        app.reply(toApplicationShouldTerminate: true)
    }
}
