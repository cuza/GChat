import AppKit
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "dev.cuza.Parley", category: "store")

@MainActor @Observable
final class ChatStore {
    var conversations: [Conversation] = []
    var messages: [Message] = [] { didSet { timelines = [:] } }
    /// Sorted timelines by draft key, kept until `messages` changes: a timeline view reads its messages several times
    /// per update, and filtering and sorting every loaded message each time showed up in profiles.
    @ObservationIgnored private var timelines: [String: [Message]] = [:]
    var selectedID: ConversationID? { didSet { if selectedID != oldValue { saveDrafts() } } }   // leaving a composer saves its draft
    var drafts: [String: String] = [:] {
        didSet { let scopes = Set(drafts.filter { !Self.blank($0.value) }.keys); if scopes != draftedScopes { draftedScopes = scopes } }
    }
    /// The draft keys whose composer holds text. It changes only when a draft starts or is cleared, so a view showing
    /// "1 draft" reads this, not `drafts`, and doesn't update on every keystroke.
    private(set) var draftedScopes: Set<String> = []
    var draftFormatting: [String: [TextStyleRange]] = [:]   // per draft key, UTF-16 ranges into the draft text
    var draftAttachments: [String: [Attachment]] = [:]   // per draft key, local files to upload on send (not cached across launches)
    var connection: ConnectionState = .offline {
        // A session that ends while in use is first renewed silently (see `onSessionLost`); the banner shows meanwhile.
        didSet { if connection == .signedOut, oldValue != .signedOut, !me.id.isEmpty { Task { await onSessionLost() } } }
    }
    @ObservationIgnored var onSessionLost: @MainActor () async -> Void = {}
    var error: String?
    // For Connection Diagnostics.
    private(set) var connectedSince: Date?
    private(set) var lastEventAt: Date?   // the last event from Google, not counting connection changes
    private(set) var reconnects = 0
    var threadID: ThreadID? { didSet { if threadID != oldValue { saveDrafts() } } }
    var info = false   // the conversation info panel, which shares the inspector with the thread
    var editing: [String: MessageID] = [:]   // per draft key: the sent message that composer is editing
    var quoting: [String: QuotedMessage] = [:]   // per draft key: the message the next send quotes (not cached across launches)
    var searchResults: [Message] = []
    /// The sidebar shortcut shown instead of a conversation; nil while a conversation shows.
    var shortcut: Shortcut? { didSet { if shortcut != oldValue { saveDrafts() } } }
    private var shortcutLists: [Shortcut: [Message]] = [:]
    var homeUnreadOnly = false   // Home's filters, kept for the session
    var homeThreadsOnly = false
    private(set) var homeThreads: [HomeThread] = []   // Home's thread rows, from the backend's last conversation list
    @ObservationIgnored private var shortcutCursors: [Shortcut: String] = [:]
    /// A message just jumped to, outlined in the timeline; it fades after `highlightDuration`, as Telegram flashes it.
    var highlightedID: MessageID? {
        didSet {
            highlightFade?.cancel()
            guard highlightedID != nil else { return }
            highlightFade = Task { [weak self, highlightDuration] in
                try? await Task.sleep(for: highlightDuration)
                guard !Task.isCancelled else { return }
                self?.highlightedID = nil
            }
        }
    }
    @ObservationIgnored var highlightDuration: Duration = .seconds(3)
    /// Voice messages whose whole transcript shows; the rest show one line, as Google Chat does.
    private(set) var openTranscripts: Set<MessageID> = []
    func toggleTranscript(_ id: MessageID) { if openTranscripts.remove(id) == nil { openTranscripts.insert(id) } }
    @ObservationIgnored private var highlightFade: Task<Void, Never>?
    var hasMore: Set<String> = []
    /// The info panel's shared items from the server, per `sharedKey`; absent until loaded, or if the server refused.
    private(set) var shared: [String: [SharedContent.Item]] = [:]
    private(set) var sharedMore: Set<String> = []
    private(set) var members: [ConversationID: [Person]] = [:]   // per conversation, from `ChatBackend.members(of:)`
    @ObservationIgnored private var memberLoads: Set<ConversationID> = []
    /// The organisation's custom emoji, for the picker and `:shortcode` suggestions; see `loadCustomEmoji`.
    private(set) var customEmoji: [CustomEmoji] = []
    @ObservationIgnored private var customEmojiLoad: Task<Void, Never>?
    @ObservationIgnored private var reactors: [MessageID: [Reaction: [Person]]] = [:]   // see `reactorsLine`
    private(set) var loading: Set<String> = []
    @ObservationIgnored private let backend: any ChatBackend
    @ObservationIgnored private let cache: LaunchCache?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var cacheTask: Task<Void, Never>?
    @ObservationIgnored private var cachedAccountID: String?
    @ObservationIgnored private var loaded: Set<String> = []
    @ObservationIgnored private var searchGeneration = 0
    private(set) var me = Person(id: "", name: "")
    // Typing, presence and read receipts.
    private(set) var typing: [String: [String: Date]] = [:]   // draft key → typist → local arrival
    /// An agent at work by draft key, shown in that composer's typing line: in the asker's thread and in the conversation.
    private(set) var activities: [String: Activity] = [:]
    struct Activity: Equatable { var person: PersonID; var label: String; var at: Date }
    private(set) var presence: [String: Presence] = [:]
    private(set) var statuses: [String: String] = [:]          // custom status text
    private(set) var readReceipts: [ConversationID: [String: Date]] = [:]   // reader → read up to
    @ObservationIgnored private var receiptsOff: Set<ConversationID> = []
    // ponytail: only threads seen this session (loaded, pushed, or labelled while connected); a thread followed earlier in a
    // conversation not loaded since counts as unfollowed. Seed it from the server's followed-threads view if replies go missing.
    @ObservationIgnored private var followed: Set<ThreadID> = []
    @ObservationIgnored private var presenceFetched: [String: Date] = [:]
    @ObservationIgnored private var notifiedReactions: Set<String> = []   // message#person#emoji already announced
    @ObservationIgnored private var typingSent: [String: Date] = [:]
    @ObservationIgnored private var watching: Set<ConversationID>?
    @ObservationIgnored private var sweepTask: Task<Void, Never>?
    /// The clock typing, presence and throttles run on; tests replace it.
    @ObservationIgnored var now: () -> Date = { .now }
    static let typingTimeout: TimeInterval = 8, typingInterval: TimeInterval = 5, presenceTTL: TimeInterval = 60
    static let unreadWindow: TimeInterval = 120   // matches NotificationPolicy's age guard
    /// Whether the user can see the window; read receipts follow it.
    @ObservationIgnored var isAppActive: @MainActor () -> Bool = { NSApplication.shared.isActive }
    /// Banners for pushed messages; nil (tests, previews) posts nothing.
    @ObservationIgnored var notifier: (any Notifier)?
    @ObservationIgnored var notificationSettings: @MainActor () -> NotificationSettings = { .current }
    // Server drafts: each composer's draft saved to Google too, so it follows the user to web and phone (see `syncDraft`).
    private(set) var serverDrafts: [String: ServerDraft] = [:]   // per draft key: Google's copy, as last saved or heard of
    @ObservationIgnored private var draftEdits: [String: Date] = [:]   // draft keys typed in since their last save, and when
    @ObservationIgnored private var draftsListed = false
    @ObservationIgnored private var draftListing: Task<Bool, Never>?
    @ObservationIgnored private var draftWrites: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var draftTimers: [String: Task<Void, Never>] = [:]
    /// Drafts a send used up (Google drops them): a late echo of one never refills a composer.
    @ObservationIgnored private var spentDrafts: Set<String> = []
    /// Sends per draft key: a save that started before the latest send finishes as a leftover, which is deleted.
    @ObservationIgnored private var draftSends: [String: Int] = [:]
    /// Google Chat's web client creates a draft a few seconds into a pause and updates it when the user leaves the composer;
    /// the idle save is a safety net. Tests shorten both.
    @ObservationIgnored var draftPause: Duration = .seconds(3)
    @ObservationIgnored var draftIdle: Duration = .seconds(30)

    init(backend: any ChatBackend, cache: LaunchCache? = nil) {
        self.backend = backend; self.cache = cache
        if let snapshot = cache?.load() {
            cachedAccountID = snapshot.accountID
            conversations = snapshot.conversations; messages = snapshot.messages
            selectedID = snapshot.selectedID; drafts = snapshot.drafts; draftFormatting = snapshot.draftFormatting
            draftEdits = snapshot.draftEdits; serverDrafts = snapshot.serverDrafts; homeThreads = snapshot.homeThreads
        }
    }
    /// No session, or it was lost before this launch connected: the welcome screen.
    var needsSignIn: Bool { connection == .signedOut && me.id.isEmpty }
    /// The session ended while the app was in use: a banner over the conversations, which stay.
    var sessionExpired: Bool { connection == .signedOut && !me.id.isEmpty }
    /// Another account connected: nothing of the previous one may show, be sent, or be cached.
    private func forgetAccount() {
        serverDrafts = [:]; draftEdits = [:]; draftsListed = false; draftTimers.values.forEach { $0.cancel() }; draftTimers = [:]
        conversations = []; homeThreads = []; messages = []; selectedID = nil; drafts = [:]; draftFormatting = [:]; draftAttachments = [:]
        quoting = [:]; searchResults = []; shortcut = nil; shortcutLists = [:]; shortcutCursors = [:]; hasMore = []; members = [:]; memberLoads = []; customEmoji = []; customEmojiLoad = nil; loaded = []; threadID = nil; editing = [:]
        typing = [:]; presence = [:]; statuses = [:]; readReceipts = [:]; receiptsOff = []; followed = []; presenceFetched = [:]; watching = nil
    }
    /// After the user signs out; cached conversations and drafts stay for the next sign-in.
    func signedOut() {
        me = Person(id: "", name: "")
        connection = .signedOut
    }
    /// Shows a failure to the user. Cancellation is not one: the work was superseded or no longer wanted.
    /// A lost session is not one either: it shows as the session-expired banner, which offers to sign in again.
    func report(_ error: Error) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled || endedSession(error) { return }
        log.error("\(ConnectionDiagnostics.redact(error.localizedDescription), privacy: .public)")
        self.error = error.localizedDescription
    }
    private func endedSession(_ error: Error) -> Bool {
        guard (error as? AuthFailure)?.endsSession == true else { return false }
        log.notice("Google no longer accepts the session: signed out")
        connection = .signedOut
        return true
    }
    var selected: Conversation? { conversations.first { $0.id == selectedID } }
    /// The conversation whose timeline is on screen: none while a shortcut is (Home keeps `selectedID` for its thread pane).
    private var openConversation: ConversationID? { shortcut == nil ? selectedID : nil }
    var unreadCount: Int { conversations.filter { !$0.muted }.reduce(0) { $0 + $1.unread } }
    func key(_ conversation: String, _ thread: String?) -> String { "\(conversation)/\(thread ?? "timeline")" }
    func timeline(_ conversation: String, thread: String? = nil) -> [Message] {
        let all = messages   // read on every call, so a view showing it still updates when messages change
        let scope = key(conversation, thread)
        if let cached = timelines[scope] { return cached }
        let sorted = all.filter { $0.conversationID == conversation && $0.threadID == thread }.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }
        timelines[scope] = sorted
        return sorted
    }
    func start() async {
        if eventTask == nil {
            let events = backend.events
            eventTask = Task { [weak self] in
                for await event in events { guard !Task.isCancelled else { break }; self?.apply(event) }
            }
        }
        if sweepTask == nil {   // Google Chat sweeps typists every 3 s; presence goes stale after 60 s
            sweepTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard let self else { return }
                    sweepTyping()
                    if isAppActive() { await refreshPresence() }
                }
            }
        }
        do {
            let known = cachedAccountID ?? (me.id.isEmpty ? nil : me.id)
            me = try await backend.connect()
            if let known, known != me.id { forgetAccount() }
            cachedAccountID = me.id
            try await refresh(reselect: true)
        } catch AuthFailure.signInRequired {
            connection = .signedOut
        } catch is CancellationError {   // superseded by a newer start, or its view went away: that one decides the state
        } catch { report(error); connection = .offline }
    }
    /// Replaces the conversation list (the server's, pin and mute included) and reloads the open conversation.
    /// A resync (`reselect: false`) keeps the open thread and edit and marks nothing read.
    func refresh(reselect: Bool = false) async throws {
        // Together, so Home never shows the new list with the old threads (a conversation flashing up as a plain row).
        let listed = try await backend.conversations()
        let threads = await backend.homeThreads()
        conversations = listed; homeThreads = threads
        let vanished = !conversations.contains(where: { $0.id == selectedID })
        if vanished { selectedID = conversations.first?.id }
        if let selectedID {
            if reselect || vanished {
                // A shortcut on screen (Home at launch) stays: the conversation opens, and is read, only when chosen.
                if shortcut == nil { await select(selectedID) }
            } else {
                loaded.remove(key(selectedID, nil))
                await load(selectedID)
                if let threadID {
                    loaded.remove(key(selectedID, threadID))
                    await load(selectedID, thread: threadID)
                }
            }
        }
        _ = await listDrafts()
        persist()
    }
    func select(_ id: String, recording: Bool = true) async {
        if recording { visit(.conversation(id)) }
        endMainWindowEdits()
        selectedID = id; threadID = nil; shortcut = nil
        loaded.remove(key(id, nil))   // no realtime yet: reselecting is how new messages arrive
        await load(id)
        await markRead(id)
        persist()
        await watchOpen()
        await refreshPresence()
    }
    /// A page already on its way is waited for, not skipped: a caller paging back (to reach an old message) must see it land.
    /// `quietly`: a background load (a Home preview) logs a failure instead of alerting.
    func load(_ id: String, thread: String? = nil, older: Bool = false, quietly: Bool = false) async {
        let scope = key(id, thread)
        if let running = pageLoads[scope] { await running.value; return }
        guard older || !loaded.contains(scope) else { return }
        // Cleared by the load itself, before anyone waiting on it resumes, so the next call starts a new page.
        let task = Task { await fetchPage(id, thread: thread, older: older, quietly: quietly); pageLoads[scope] = nil; loading.remove(scope) }
        pageLoads[scope] = task; loading.insert(scope)
        await task.value
    }
    @ObservationIgnored private var pageLoads: [String: Task<Void, Never>] = [:]
    private func fetchPage(_ id: String, thread: String?, older: Bool, quietly: Bool = false) async {
        let scope = key(id, thread)
        do {
            let page = try await backend.messages(in: id, thread: thread, before: older ? timeline(id, thread: thread).first?.createdAt : nil)
            if !older {
                messages.removeAll { $0.conversationID == id && $0.threadID == thread && $0.delivery == .sent }
            }
            page.messages.forEach(upsert)
            loaded.insert(scope)
            if page.hasMore { hasMore.insert(scope) } else { hasMore.remove(scope) }
            persist()
        } catch where quietly {
            log.error("Background load failed: \(ConnectionDiagnostics.redact(error.localizedDescription), privacy: .public)")
        } catch { report(error) }
    }
    /// The timeline neared its top: load one older page, one request at a time per timeline. A page already on its
    /// way is waited for first, not a reason to drop the request: a reload of the newest page (reopening the
    /// conversation) lands the same rows, so the timeline would never ask again.
    func loadOlderIfNeeded(_ id: String, thread: String? = nil) async {
        let scope = key(id, thread)
        if let running = pageLoads[scope] { await running.value }
        guard hasMore.contains(scope), !loading.contains(scope) else { return }
        await load(id, thread: thread, older: true)
    }
    /// A click on a quote: highlights the quoted message, paging back through history (at most 10 pages) to reach it.
    func showQuoted(_ id: MessageID, in conversation: ConversationID, pages: Int = 10) async {
        for _ in 0..<pages {
            if let quoted = messages.first(where: { $0.id == id }) {
                if let thread = quoted.threadID, thread != threadID { await openThread(quoted) }
                highlightedID = id
                return
            }
            guard hasMore.contains(key(conversation, nil)) else { return }
            await load(conversation, older: true)
        }
    }
    /// "Show in Chat" on a shared item: its message highlighted, in its thread when it is a reply.
    func showShared(_ item: SharedContent.Item, in conversation: ConversationID) async {
        guard let id = item.messageID else { return }
        await show(id, in: conversation)
    }
    /// A Google Chat link in a message: opens its conversation, and its message when it names one.
    /// Returns false when Parley doesn't know the conversation, for the caller to open the link elsewhere.
    func open(_ link: ChatLink) async -> Bool {
        guard let conversation = link.conversations.first(where: { id in conversations.contains { $0.id == id } }) else { return false }
        await select(conversation)
        if let topic = link.topic { await show("\(conversation)/\(topic)/\(link.message ?? topic)", in: conversation) }
        return true
    }
    /// A message highlighted where it is: in its thread when it is a reply, else in the timeline, paging back to it.
    // ponytail: pages back through at most 50 pages of history; older messages stay unreachable until there is a jump-to-date.
    private func show(_ id: MessageID, in conversation: ConversationID) async {
        let parts = id.split(separator: "/")   // <conversation>/<topic>/<message>: a reply's message differs from its topic
        if parts.count >= 2, parts[parts.count - 1] != parts[parts.count - 2] {
            await openThread(parts.dropLast().joined(separator: "/") + "/" + parts[parts.count - 2], in: conversation)
            highlightedID = id
            return
        }
        await showQuoted(id, in: conversation, pages: 50)
    }
    func openThread(_ message: Message) async {
        await openThread(message.threadID ?? message.id, in: message.conversationID)
    }
    private func openThread(_ thread: ThreadID, in conversation: ConversationID) async {
        threadID = thread; info = false
        loaded.remove(key(conversation, thread))
        await load(conversation, thread: thread)
    }
    /// Posts a new Google Meet meeting in the conversation; its link, to open, or nil when refused (the error shows).
    func sendMeetLink(in id: ConversationID) async -> URL? {
        do {
            let message = try await backend.sendMeetLink(in: id)
            upsert(message)
            return message.attachments.first { $0.kind == .call }?.url
        } catch { report(error); return nil }
    }
    /// Whether a restored window's conversation is this account's; nil until the list has come.
    func hasConversation(_ id: ConversationID) -> Bool? {
        conversations.isEmpty ? nil : conversations.contains { $0.id == id }
    }
    /// The open thread, closed in the pane so it can go to its own window.
    func detachThread(in conversation: ConversationID) -> ThreadRef? {
        guard let thread = threadID else { return nil }
        threadID = nil
        return ThreadRef(conversation: conversation, thread: thread)
    }
    // MARK: Back and forward, through the conversations and shortcuts opened (⌘[ and ⌘])

    enum Place: Hashable { case conversation(ConversationID), shortcut(Shortcut) }
    private(set) var backPlaces: [Place] = []
    private(set) var forwardPlaces: [Place] = []
    var canGoBack: Bool { !backPlaces.isEmpty }
    var canGoForward: Bool { !forwardPlaces.isEmpty }
    private var place: Place? { shortcut.map(Place.shortcut) ?? selectedID.map(Place.conversation) }
    /// Opening a new place: the current one goes on the back list and the forward list ends, as in a browser.
    private func visit(_ next: Place) {
        guard let place, place != next else { return }
        backPlaces.append(place); forwardPlaces = []
        if backPlaces.count > 100 { backPlaces.removeFirst() }
    }
    func goBack() async {
        guard let to = backPlaces.popLast() else { return }
        if let place { forwardPlaces.append(place) }
        await open(to)
    }
    func goForward() async {
        guard let to = forwardPlaces.popLast() else { return }
        if let place { backPlaces.append(place) }
        await open(to)
    }
    private func open(_ place: Place) async {
        switch place {
        case .conversation(let id): await select(id, recording: false)
        case .shortcut(let shortcut): await openShortcut(shortcut, recording: false)
        }
    }

    /// A clicked notification: its conversation, and its thread for a reply.
    func open(conversation: ConversationID, thread: ThreadID?) async {
        await select(conversation)
        if let thread { await openThread(thread, in: conversation) }
    }
    func apply(_ event: ChatEvent) {
        if case .connectionChanged(let state) = event {
            if state != .connected { connectedSince = nil } else if connection != .connected { connectedSince = now() }
            if state == .reconnecting, connection != .reconnecting { reconnects += 1 }
        } else { lastEventAt = now() }
        switch event {
        case .messageUpserted(let message):
            let isNew = !messages.contains { $0.id == message.id }
            upsert(message)
            // A newer reply in a thread Home lists moves its row up.
            // ponytail: only threads already listed; a reply in another followed thread shows on the next refresh.
            if let thread = message.threadID, let i = homeThreads.firstIndex(where: { $0.id == thread }), message.createdAt > homeThreads[i].latest.createdAt {
                homeThreads[i].latest = message
                homeThreads[i].time = max(homeThreads[i].time, message.createdAt)
                if message.sender.id != me.id, !(shortcut == .home && threadID == thread) { homeThreads[i].unread = true }
            }
            if isNew, message.sender.id != me.id {   // a message ends its sender's typing, and they're evidently here
                for scope in typing.keys where scope.hasPrefix(message.conversationID + "/") { typing[scope]?[message.sender.id] = nil }
                if now().timeIntervalSince(message.createdAt) < Self.presenceTTL { markActive(message.sender.id) }
            }
            if isNew, message.sender.id != me.id {
                let room = conversations.first { $0.id == message.conversationID }
                // A call notifies even with its DM on screen, as a phone call would.
                let call = NotificationPolicy.isIncomingCall(message, in: room, me: me.id, now: now())
                let notification = NotificationPolicy.notification(
                    for: message, in: room, me: me.id, openConversation: selectedID,
                    openThread: threadID, appActive: !call && isAppActive(), settings: notificationSettings(),
                    threadFollowed: message.threadID.map(followed.contains) ?? false)
                    .map { call ? $0.incomingCall(join: message.attachments.first { $0.kind == .call }?.url) : $0 }
                log.notice("message pushed: \(notification == nil ? "no banner (policy)" : self.notifier == nil ? "no notifier" : "banner", privacy: .public)")
                if let notification { notifier?.post(notification) }
            }
            // Only a fresh message is unread: a reaction or edit pushes an old message the user has long since read.
            if isNew, !message.isSystem, message.threadID == nil, message.sender.id != me.id, message.conversationID != openConversation,
               now().timeIntervalSince(message.createdAt) < Self.unreadWindow,
               let i = conversations.firstIndex(where: { $0.id == message.conversationID }) {
                conversations[i].unread += 1
            }
            // ponytail: one read receipt per pushed message; debounce if busy rooms make this chatty.
            if isNew, message.sender.id != me.id, message.conversationID == openConversation, isAppActive() {
                Task { await markRead(message.conversationID) }
            }
        case .messageDeleted(let id): messages.removeAll { $0.id == id }
        case .conversationUpserted(var room):   // changed elsewhere; a new one is the most recent
            // The open conversation stays read: its server read state can trail what is on screen (my own send, a membership change).
            if room.id == selectedID, room.unread > 0, isAppActive() {
                room.unread = 0
                Task { await markRead(room.id) }
            }
            if let i = conversations.firstIndex(where: { $0.id == room.id }) { conversations[i] = room } else { conversations.insert(room, at: 0) }
        case .conversationRemoved(let id):
            conversations.removeAll { $0.id == id }
            messages.removeAll { $0.conversationID == id }
            notifier?.clear(conversation: id)
            if selectedID == id {
                editing = editing.filter { !$0.key.hasPrefix(id + "/") }
                selectedID = conversations.first?.id; threadID = nil
                if let next = selectedID { Task { await select(next) } }
            }
        case .threadFollowChanged(let thread, let following):
            if following { followed.insert(thread) } else { followed.remove(thread) }
        case .reacted(let id, let emoji, let person, let added):
            // ponytail: only reactions to my messages loaded here notify; fetch the message if older ones go unannounced.
            let target = messages.first { $0.id == id }
            log.notice("reaction pushed: \(added ? "added" : "removed", privacy: .public), message \(target == nil ? "not loaded" : target?.sender.id == self.me.id ? "mine" : "someone else's", privacy: .public)")
            guard added, let message = target,
                  let notification = NotificationPolicy.reaction(
                    emoji, by: self.person(person, in: message.conversationID) ?? Person(id: person, name: name(of: person, in: message.conversationID)),
                    to: message, in: conversations.first { $0.id == message.conversationID }, me: me.id, openConversation: selectedID,
                    openThread: threadID, appActive: isAppActive(), settings: notificationSettings()),
                  notifiedReactions.insert(notification.id).inserted else { return }
            notifier?.post(notification)
            return
        case .readStateChanged(let id, let count):
            if let i = conversations.firstIndex(where: { $0.id == id }) { conversations[i].unread = count }
            if count == 0 { notifier?.clear(conversation: id) }   // read here or on another device
        case .connectionChanged(let state):
            connection = state
            if state != .connected { typing = [:] }   // nobody's typing reaches us now
        case .activityChanged(let id, let thread, let person, let label):
            for scope in Set([key(id, nil), key(id, thread)]) {
                activities[scope] = label.map { Activity(person: person, label: $0, at: now()) }
            }
            return
        case .typingChanged(let id, let thread, let person, let isTyping):
            if isTyping { typing[key(id, thread), default: [:]][person] = now(); markActive(person) }
            else { typing[key(id, thread)]?[person] = nil }
            return
        case .readReceiptsChanged(let id, let reads, let enabled):
            if enabled == false { receiptsOff.insert(id); readReceipts[id] = nil; return }
            if enabled == true { receiptsOff.remove(id) }
            if !receiptsOff.contains(id) { readReceipts[id, default: [:]].merge(reads, uniquingKeysWith: max) }
            return
        case .presenceChanged(let person, let state, let status):
            statuses[person] = status
            if let state { presence[person] = state; presenceFetched[person] = now() }
            else if presence[person] == .doNotDisturb { presence[person] = nil; presenceFetched[person] = nil }   // DND over: ask again
            return
        case .resync:
            Task { do { try await refresh() } catch { report(error) } }
        case .draftChanged(let draft):
            let scope = key(draft.conversationID, draft.threadID)
            if spentDrafts.contains(draft.id) { break }   // sent: an echo of an earlier save, not a draft
            // Our own save comes back too, possibly after a newer one: only a newer copy counts.
            if let held = serverDrafts[scope], held.id == draft.id, held.updatedAt >= draft.updatedAt { break }
            serverDrafts[scope] = draft
            // The user typing here wins: their text replaces this at the next save.
            if draftEdits[scope] == nil, draftWrites[scope] == nil, !isEditing(scope) { fill(scope, with: draft) }
        case .draftDeleted(let id):
            guard let (scope, held) = serverDrafts.first(where: { $0.value.id == id }) else { break }   // ours, or a send's
            serverDrafts[scope] = nil
            // Sent or deleted elsewhere: the composer empties, unless it holds text not yet saved.
            if draftEdits[scope] == nil, drafts[scope] == held.text, !isEditing(scope) { drafts[scope] = nil; draftFormatting[scope] = nil }
        }
        persist()
    }
    private func markActive(_ person: String) {
        guard person != me.id else { return }
        if presence[person] != .doNotDisturb { presence[person] = .available }
        presenceFetched[person] = now()
    }
    /// Typists whose last "typing" arrived more than 8 s ago are gone. Google Chat times from the server's
    /// start time, which a fast Mac clock would expire on arrival, so this uses the local arrival time.
    func sweepTyping() {
        let cutoff = now().addingTimeInterval(-Self.typingTimeout)
        activities = activities.filter { $0.value.at > now().addingTimeInterval(-15) }   // an agent repeats its status every few seconds
        for (scope, people) in typing where people.values.contains(where: { $0 <= cutoff }) {
            let kept = people.filter { $0.value > cutoff }
            typing[scope] = kept.isEmpty ? nil : kept
        }
    }
    /// "Ask Gemini · Collecting info…" while an agent works where this composer is; `name` for the agent's, else looked up.
    func activityLine(_ conversation: ConversationID, thread: ThreadID?, name: String? = nil) -> String? {
        guard let activity = activities[key(conversation, thread)] else { return nil }
        return "\(name ?? self.name(of: activity.person, in: conversation)) · \(activity.label)…"
    }
    func typists(_ conversation: ConversationID, thread: ThreadID? = nil) -> [String] {
        (typing[key(conversation, thread)] ?? [:]).keys.sorted()
    }
    static func typingLine(_ names: [String]) -> String? {
        let first = names.map { String($0.split(separator: " ").first ?? Substring($0)) }
        switch first.count {
        case 0: return nil
        case 1: return "\(first[0]) is typing…"
        case 2, 3: return "\(ListFormatter.localizedString(byJoining: first)) are typing…"
        default: return "Several people are typing…"
        }
    }
    /// The composer's text changed: tell the others at most every 5 s per composer, never for blank text or while
    /// editing a sent message. There is no "stopped"; receivers time it out.
    func typed(_ text: String, conversation: ConversationID, thread: ThreadID?) async {
        let scope = key(conversation, thread)
        guard editing[scope] == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let last = typingSent[scope], now().timeIntervalSince(last) < Self.typingInterval { return }
        typingSent[scope] = now()
        try? await backend.sendTyping(conversation: conversation, thread: thread)
    }
    // ponytail: only the main window's conversation is watched; add the extra windows' ones if typing is wanted there too.
    private func watchOpen() async {
        let open: Set<ConversationID> = selectedID.map { [$0] } ?? []
        guard open != watching else { return }
        watching = open
        await backend.watch(open)
    }
    /// Asks, in one batch, for everyone whose presence is over 60 s old among 1:1 partners and the open conversation's members.
    // ponytail: the 50 most recent 1:1 DMs; page through the rest if the sidebar shows more dots than that.
    func refreshPresence() async {
        let partners = conversations.compactMap(partner).prefix(50)
        let open = selectedID.map(mentionCandidates)?.map(\.id) ?? []
        let stale = Set(partners + open).subtracting([me.id, ""]).filter { id in
            presenceFetched[id].map { now().timeIntervalSince($0) >= Self.presenceTTL } ?? true
        }
        guard !stale.isEmpty else { return }
        for id in stale { presenceFetched[id] = now() }   // also spaces out retries after a failure
        try? await backend.fetchPresence(stale.sorted())
    }
    /// Each reader under my newest message their read time covers: DMs and group DMs only.
    func seen(in conversation: Conversation) -> [MessageID: [String]] {
        guard conversation.kind != .space, let reads = readReceipts[conversation.id] else { return [:] }
        let mine = timeline(conversation.id).filter { $0.sender.id == me.id && $0.delivery == .sent }
        var marks: [MessageID: [String]] = [:]
        for (reader, time) in reads.sorted(by: { $0.key < $1.key }) {
            if let newest = mine.last(where: { $0.createdAt <= time }) { marks[newest.id, default: []].append(reader) }
        }
        return marks
    }
    /// Everyone whose receipt covers `message`, for "Seen by …".
    func readers(of message: Message) -> [String] {
        (readReceipts[message.conversationID] ?? [:]).filter { $0.value >= message.createdAt }.keys.sorted()
    }
    /// "Alice, Bob, and You" for a reaction pill's hover card, fetched once per reaction state; nil when the lookup failed.
    /// Keyed by the `Reaction` value, so a reaction that changes (people or count) is looked up again.
    func reactorsLine(_ reaction: Reaction, on message: MessageID) async -> String? {
        if reactors[message]?[reaction] == nil {
            guard let people = try? await backend.reactors(of: message, emoji: reaction.emoji, custom: reaction.custom) else { return nil }
            reactors[message, default: [:]][reaction] = people
        }
        let people = reactors[message]?[reaction] ?? []
        return Self.reactorsLine(names: people.map { $0.id == me.id ? "You" : $0.name }, count: reaction.people.count)
    }
    /// Others first, then "You", as Google Chat lists them; people the server left out are counted. No names yet: the count.
    static func reactorsLine(names: [String], count: Int) -> String {
        guard !names.isEmpty else { return count == 1 ? "1 person" : "\(count) people" }
        var list = names.filter { $0 != "You" } + names.filter { $0 == "You" }
        if count > names.count { list.append(count - names.count == 1 ? "1 other" : "\(count - names.count) others") }
        return ListFormatter.localizedString(byJoining: list)
    }
    /// The other person in a 1:1 DM, whose presence the sidebar and header show.
    func partner(in conversation: Conversation) -> String? {
        conversation.kind == .direct ? conversation.members.first { $0.id != me.id }?.id : nil
    }
    func name(of person: String, in conversation: ConversationID) -> String {
        let known = (members[conversation] ?? []) + (conversations.first { $0.id == conversation }?.members ?? [])
        return (known.first { $0.id == person } ?? messages.first { $0.sender.id == person }?.sender)
            .map(\.name).flatMap { $0 == "Unknown" ? nil : $0 } ?? "Someone"
    }
    /// Who `id` is, as far as the conversation knows: its members, then the senders of loaded messages.
    func person(_ id: PersonID, in conversation: ConversationID) -> Person? {
        let known = (members[conversation] ?? []) + (conversations.first { $0.id == conversation }?.members ?? [])
        return known.first { $0.id == id && $0.name != "Unknown" } ?? messages.first { $0.sender.id == id }?.sender
    }
    /// A card button's action (a Drive comment's Reply, Resolve): sent with the card's inputs; the app's answer replaces the
    /// message. A refusal says why.
    func clickCard(_ message: Message, action: Data, inputs: [Card.Input]) async {
        do { if let updated = try await backend.clickCard(message.id, action: action, inputs: inputs) { upsert(updated); persist() } }
        catch { report(error) }
    }
    /// Where dismissed cards are remembered; tests use their own.
    @ObservationIgnored var defaults = UserDefaults.standard
    private static let dismissedCardsKey = "dismissedCards"
    /// Hides a message's dismissible cards (an app suggestion's "Don't install"), in Parley only, for good.
    func dismissCard(of message: Message) {
        let dismissed = defaults.stringArray(forKey: Self.dismissedCardsKey) ?? []
        // ponytail: an ever-growing list of message ids; trim it if it ever gets long.
        if !dismissed.contains(message.id) { defaults.set(dismissed + [message.id], forKey: Self.dismissedCardsKey) }
        if let current = messages.first(where: { $0.id == message.id }) { upsert(current); persist() }   // the launch cache too
    }
    private func upsert(_ message: Message) {
        var message = message
        if message.attachments.contains(where: { $0.card?.dismiss != nil }),
           defaults.stringArray(forKey: Self.dismissedCardsKey)?.contains(message.id) == true {
            message.attachments.removeAll { $0.card?.dismiss != nil }
        }
        if let i = messages.firstIndex(where: { $0.id == message.id }) { messages[i] = message } else { messages.append(message) }
        // Following, as the server does it: a thread loaded as followed, or one I start, reply in or am @mentioned in.
        if message.following || message.sender.id == me.id || NotificationPolicy.mentions(message, me: me.id) {
            followed.insert(message.threadID ?? message.id)
        }
    }
    func setDraft(_ text: String, formatting: [TextStyleRange] = [], conversation: String, thread: String?) {
        let scope = key(conversation, thread)
        let changed = drafts[scope, default: ""] != text || draftFormatting[scope, default: []] != formatting
        drafts[scope] = text; draftFormatting[scope] = formatting.isEmpty ? nil : formatting
        if changed, !isEditing(scope) { draftEdits[scope] = now(); scheduleDraftSave(scope) }   // an edit's text is no draft
        persist()
    }
    // MARK: Server drafts
    /// Whether `scope` holds a sent message being edited, whose text is no draft.
    private func isEditing(_ scope: String) -> Bool {
        editing[scope] != nil
    }
    /// A draft key's conversation and thread, for a conversation the sidebar knows; nil for any other.
    private func place(_ scope: String) -> (ConversationID, ThreadID?)? {
        guard let room = conversations.first(where: { scope.hasPrefix($0.id + "/") }) else { return nil }
        let rest = String(scope.dropFirst(room.id.count + 1))
        return (room.id, rest == "timeline" ? nil : rest)
    }
    private func fill(_ scope: String, with draft: ServerDraft) {
        drafts[scope] = draft.text; draftFormatting[scope] = draft.formatting.isEmpty ? nil : draft.formatting; draftEdits[scope] = nil
    }
    private static func blank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// After a pause in typing, a draft Google doesn't have yet is created (or a cleared one deleted); after a longer
    /// idle, a changed one is updated too.
    private func scheduleDraftSave(_ scope: String) {
        draftTimers[scope]?.cancel()
        draftTimers[scope] = Task { [weak self, draftPause, draftIdle] in
            try? await Task.sleep(for: draftPause)
            guard !Task.isCancelled else { return }
            await self?.syncDraft(scope, updating: false)
            try? await Task.sleep(for: draftIdle - draftPause)
            guard !Task.isCancelled else { return }
            await self?.syncDraft(scope)
        }
    }
    /// Leaving composers (another conversation or thread, the window losing focus, quitting) saves every draft typed in
    /// since its last save. The task ends when they are saved, or failed.
    @discardableResult func saveDrafts() -> Task<Void, Never> {
        let scopes = draftsListed ? draftEdits.keys.sorted() : []   // before the first list the merge pushes them
        return Task { for scope in scopes { await syncDraft(scope) } }
    }
    /// Brings Google's copy of one composer's draft in line with the composer: created when it has text Google lacks, deleted
    /// when it is empty, updated (`updating`) when its text or formatting changed. One write at a time per composer; a
    /// failure keeps the text and the edit mark, so the next trigger tries again.
    func syncDraft(_ scope: String, updating: Bool = true) async {
        while let running = draftWrites[scope] { await running.value }
        if !draftsListed { guard await listDrafts() else { return } }
        guard !isEditing(scope), let (conversation, thread) = place(scope) else { return }
        let text = drafts[scope] ?? "", formatting = draftFormatting[scope] ?? []
        let held = serverDrafts[scope]
        if Self.blank(text) ? held == nil : held.map({ $0.text == text && $0.formatting == formatting }) ?? false {
            draftEdits[scope] = nil   // nothing to save
            return
        }
        if held != nil, !Self.blank(text), !updating { return }
        let sends = draftSends[scope, default: 0]
        let task = Task {
            do {
                if Self.blank(text), let held {
                    try await backend.deleteDraft(held)
                    if serverDrafts[scope]?.id == held.id { serverDrafts[scope] = nil }
                } else {
                    let saved = try await backend.saveDraft(ServerDraft(id: held?.id ?? "", conversationID: conversation, threadID: thread,
                                                                        text: text, formatting: formatting))
                    if draftSends[scope, default: 0] != sends {
                        // The message went while this was on its way: Google now holds its old text as a draft. Undone.
                        spentDrafts.insert(saved.id)
                        try await backend.deleteDraft(saved)
                        draftWrites[scope] = nil
                        return
                    }
                    serverDrafts[scope] = saved
                }
                if drafts[scope] ?? "" == text, draftFormatting[scope] ?? [] == formatting { draftEdits[scope] = nil }
            } catch {
                log.error("draft not saved: \(ConnectionDiagnostics.redact(error.localizedDescription), privacy: .public)")
                _ = endedSession(error)
            }
            draftWrites[scope] = nil
            persist()
        }
        draftWrites[scope] = task
        await task.value
    }
    /// Google's drafts, merged with this Mac's: a draft only Google has fills its composer; one only this Mac has is pushed,
    /// unless it was saved before and Google no longer has it (sent or deleted elsewhere); when both have one, the newer
    /// wins, by Google's update time against the last local edit. False when the list failed; the next save asks again.
    @discardableResult func listDrafts() async -> Bool {
        if let draftListing { return await draftListing.value }
        let listing = Task { () -> Bool in
            defer { draftListing = nil }
            let list: [ServerDraft]
            do { list = try await backend.drafts() } catch {
                log.error("drafts not listed: \(ConnectionDiagnostics.redact(error.localizedDescription), privacy: .public)")
                _ = endedSession(error)
                return false
            }
            let known = serverDrafts
            serverDrafts = Dictionary(list.filter { !spentDrafts.contains($0.id) }.map { (key($0.conversationID, $0.threadID), $0) },
                                      uniquingKeysWith: { $0.updatedAt > $1.updatedAt ? $0 : $1 })
            draftsListed = true
            var push: [String] = []
            for (scope, draft) in serverDrafts where !isEditing(scope) {
                if let edited = draftEdits[scope], edited > draft.updatedAt { push.append(scope) } else { fill(scope, with: draft) }
            }
            for (scope, text) in drafts where serverDrafts[scope] == nil && !Self.blank(text) && !isEditing(scope) {
                if draftEdits[scope] == nil, known[scope]?.text == text { drafts[scope] = nil; draftFormatting[scope] = nil }
                else { push.append(scope) }
            }
            for scope in push.sorted() { Task { await syncDraft(scope) } }
            persist()
            return true
        }
        draftListing = listing
        return await listing.value
    }
    /// The Drafts shortcut: every composer holding a draft, newest first. `updatedAt` is when it last changed, here or on
    /// Google (`.distantPast` when unknown).
    func draftList() -> [ServerDraft] {
        drafts.compactMap { scope, text -> ServerDraft? in
            guard !Self.blank(text), !isEditing(scope), let (conversation, thread) = place(scope) else { return nil }
            let edited = draftEdits[scope].flatMap { $0 == .distantPast ? nil : $0 }
            return ServerDraft(id: serverDrafts[scope]?.id ?? "", conversationID: conversation, threadID: thread, text: text,
                               formatting: draftFormatting[scope] ?? [], updatedAt: edited ?? serverDrafts[scope]?.updatedAt ?? .distantPast)
        }.sorted { $0.updatedAt == $1.updatedAt ? $0.conversationID < $1.conversationID : $0.updatedAt > $1.updatedAt }
    }
    /// The threads in `conversation` whose reply box holds a draft, for the "1 draft" under their first message.
    func threadsWithDrafts(in conversation: ConversationID) -> Set<ThreadID> {
        Set(draftedScopes.compactMap { scope -> ThreadID? in
            guard !isEditing(scope), let (room, thread) = place(scope), room == conversation else { return nil }
            return thread
        })
    }
    /// People who can be @-mentioned: the conversation's full member list once loaded, else the members it came with; never me.
    func mentionCandidates(_ conversation: ConversationID) -> [Person] {
        (members[conversation] ?? conversations.first { $0.id == conversation }?.members ?? []).filter { $0.id != me.id }
    }
    /// Fetches a conversation's members once per launch; a failure keeps the fallback and allows a later retry.
    func sharedKey(_ conversation: ConversationID, _ category: SharedCategory) -> String { "\(conversation)/\(category.rawValue)" }
    /// The first page of a tab when it first shows, or the next page. A failure keeps the panel on loaded messages.
    func loadShared(_ category: SharedCategory, in conversation: ConversationID, more: Bool = false) async {
        let key = sharedKey(conversation, category)
        guard more ? sharedMore.contains(key) : shared[key] == nil else { return }
        sharedMore.remove(key)   // one request at a time
        do {
            let page = try await backend.shared(category, in: conversation, after: more ? shared[key]?.last : nil)
            var items = shared[key] ?? []
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) }
            shared[key] = items
            if page.hasMore { sharedMore.insert(key) }
        } catch is CancellationError {
            if more { sharedMore.insert(key) }
        } catch {
            if (error as? AuthFailure)?.endsSession == true { report(error) }
            if more { sharedMore.insert(key) }
        }
    }

    /// Once a session, when a picker or the composer first needs them; a failure leaves the list empty and allows a retry.
    func loadCustomEmoji() async {
        if let customEmojiLoad { return await customEmojiLoad.value }
        let load = Task {
            do { customEmoji = try await backend.customEmojis() } catch {
                if case .http(403)? = error as? AuthFailure { return }   // personal accounts have none: don't ask again
                customEmojiLoad = nil
                if (error as? AuthFailure)?.endsSession == true { report(error) }
            }
        }
        customEmojiLoad = load
        await load.value
    }

    func loadMembers(_ conversation: ConversationID) async {
        guard members[conversation] == nil, !memberLoads.contains(conversation) else { return }
        memberLoads.insert(conversation); defer { memberLoads.remove(conversation) }
        if let people = try? await backend.members(of: conversation), !people.isEmpty { members[conversation] = people }
    }
    /// Adds files to the draft; ones Google Chat would refuse (folders, empty, over 200 MB) are reported and left out.
    func attach(_ urls: [URL], conversation: String, thread: String?) {
        let scope = key(conversation, thread)
        var refused: [String] = []
        for url in urls {
            do { draftAttachments[scope, default: []].append(try .localFile(at: url)) } catch { refused.append(error.localizedDescription) }
        }
        if !refused.isEmpty { error = refused.joined(separator: "\n") }
    }
    func detach(_ attachment: Attachment, conversation: String, thread: String?) {
        draftAttachments[key(conversation, thread)]?.removeAll { $0 == attachment }
    }
    func send(conversation: String, thread: String? = nil) async {
        let scope = key(conversation, thread)
        let (text, formatting) = Self.trimmed(drafts[scope, default: ""], draftFormatting[scope] ?? [])
        if let editingID = editing[scope] {
            guard !text.isEmpty else { return }
            do { try await backend.edit(editingID, text: text, formatting: formatting); editing[scope] = nil; setDraft("", conversation: conversation, thread: thread) }
            catch { report(error) }
            return
        }
        let files = draftAttachments[scope] ?? []
        guard !text.isEmpty || !files.isEmpty || quoting[scope]?.forwardedFrom != nil else { return }   // a forward needs no note
        setDraft("", conversation: conversation, thread: thread)
        draftAttachments[scope] = nil
        let quote = quoting.removeValue(forKey: scope)
        // The send names the draft, and the server drops it; nothing is left to save here.
        draftTimers.removeValue(forKey: scope)?.cancel(); draftEdits[scope] = nil
        let draft = serverDrafts.removeValue(forKey: scope)?.id
        if let draft { spentDrafts.insert(draft) }
        draftSends[scope, default: 0] += 1
        await sendNew(text, formatting: formatting, attachments: files, quote: quote, serverDraft: draft, conversation: conversation, thread: thread)
    }
    /// Sends a picked GIF on its own, as Google Chat does; the local echo shows it as an image attachment.
    /// Fetches a picked GIF from its CDN; injectable for tests.
    var download: (URL) async throws -> Data = { try await URLSession.shared.data(from: $0).0 }
    /// Sent as an upload: the server drops a client-made URL chip for GIPHY links and stores an empty message.
    func sendGif(_ gif: Attachment, conversation: String, thread: String? = nil) async {
        guard let url = gif.url else { return }
        do {
            let name = (gif.name.isEmpty ? "GIF" : gif.name).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let folder = FileManager.default.temporaryDirectory.appending(path: "Parley Uploads/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: name + ".gif")
            try await download(url).write(to: file)
            await sendNew("", attachments: [try .localFile(at: file)], conversation: conversation, thread: thread)
        } catch { report(error) }
    }
    /// Sends a recording on its own, as Google Chat does: an upload named and typed like its own recordings, with the voice metadata.
    func sendVoice(_ file: URL, duration: TimeInterval, waveform: [Int], conversation: String, thread: String? = nil) async {
        let voice = Attachment(name: file.lastPathComponent, contentType: Voice.contentType, kind: .voice, url: file,
                               voice: Voice(duration: duration, waveform: waveform))
        await sendNew("", attachments: [voice], conversation: conversation, thread: thread)
    }
    /// A notification's inline reply: sent without touching the draft, and the conversation counts as read, as Messages does.
    func reply(_ text: String, conversation: ConversationID, thread: ThreadID?) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await sendNew(text, conversation: conversation, thread: thread)
        await markRead(conversation)
    }
    private func sendNew(_ text: String, formatting: [TextStyleRange] = [], attachments: [Attachment] = [], quote: QuotedMessage? = nil,
                         serverDraft: String? = nil, conversation: String, thread: String?) async {
        let pending = Message(id: "local-\(UUID())", conversationID: conversation, threadID: thread, sender: me, text: text,
                              delivery: .pending, attachments: attachments, formatting: formatting, quote: quote)
        upsert(pending)
        await deliver(pending, serverDraft: serverDraft)
    }
    /// The draft without surrounding whitespace, its ranges shifted and clipped to match (UTF-16 offsets).
    static func trimmed(_ text: String, _ formatting: [TextStyleRange]) -> (String, [TextStyleRange]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let found = text.range(of: trimmed) else { return (trimmed, []) }
        let lead = text.utf16.distance(from: text.startIndex, to: found.lowerBound), count = trimmed.utf16.count
        return (trimmed, formatting.compactMap { range in
            let start = max(0, range.start - lead), end = min(count, range.start + range.length - lead)
            return end > start ? TextStyleRange(style: range.style, start: start, length: end - start) : nil
        })
    }
    /// Uploads the echo's local files first, keeping each finished upload on the echo so a retry only redoes what failed.
    // ponytail: a retry no longer names the draft; if the send never reached Google, its draft comes back at the next launch.
    private func deliver(_ pending: Message, serverDraft: String? = nil) async {
        var pending = pending
        do {
            for (index, file) in pending.attachments.enumerated() where file.isLocalFile && file.uploadToken == nil {
                pending.attachments[index] = try await backend.upload(file, to: pending.conversationID, thread: pending.threadID)
                upsert(pending)
            }
            let sent = try await backend.send(MessageDraft(text: pending.text, localID: pending.id, formatting: pending.formatting,
                                                           uploads: pending.attachments.filter(\.isLocalFile), quoting: pending.quote,
                                                           serverDraftID: serverDraft),
                                               to: pending.conversationID, thread: pending.threadID)
            messages.removeAll { $0.id == pending.id }; upsert(sent)
        } catch {
            var failed = pending; failed.delivery = .failed; upsert(failed)
            _ = endedSession(error)
        }
        persist()
    }
    func retry(_ message: Message) async {
        guard message.delivery == .failed else { return }
        var pending = message; pending.delivery = .pending; upsert(pending)
        await deliver(pending)
    }
    /// The message `conversation`'s composer (or its `thread`'s) is editing.
    func editingID(_ conversation: ConversationID, thread: ThreadID?) -> MessageID? { editing[key(conversation, thread)] }
    /// Leaving what the main window shows ends the edits in its composers (the conversation's and its thread pane's) and
    /// clears their text, which is the message's, not a draft. A thread in its own window keeps its edit.
    private func endMainWindowEdits() {
        guard let room = selectedID else { return }
        for scope in [key(room, nil)] + (threadID.map { [key(room, $0)] } ?? []) where editing.removeValue(forKey: scope) != nil {
            drafts[scope] = ""; draftFormatting[scope] = nil
        }
    }
    func edit(_ message: Message) {
        guard message.sender.id == me.id, message.delivery == .sent else { return }
        editing[key(message.conversationID, message.threadID)] = message.id
        quoting[key(message.conversationID, message.threadID)] = nil
        setDraft(message.text, formatting: message.formatting, conversation: message.conversationID, thread: message.threadID)
    }
    /// Quote-replies to `message` from its own composer (the conversation's, or its thread's); ends an edit there.
    /// Without a server update time it names the create time.
    func quote(_ message: Message) {
        guard message.delivery == .sent, !message.isSystem else { return }
        if editing.removeValue(forKey: key(message.conversationID, message.threadID)) != nil { setDraft("", conversation: message.conversationID, thread: message.threadID) }
        quoting[key(message.conversationID, message.threadID)] = QuotedMessage(
            sender: message.sender.name, text: QuotedMessage.summary(text: TextStyleRange.plain(message.text, message.formatting), attachments: message.attachments), id: message.id,
            lastUpdateMicros: message.lastUpdateMicros ?? Int64((message.createdAt.timeIntervalSince1970 * 1_000_000).rounded()),
            media: message.attachments.first { $0.kind == .image || $0.kind == .video })
    }
    /// Forward…: `message` waits above `destination`'s composer, as in Google Chat, and goes with the next send there.
    func forward(_ message: Message, to destination: ConversationID) {
        guard message.delivery == .sent, !message.isSystem else { return }
        var forward = QuotedMessage(sender: message.sender.name, text: QuotedMessage.summary(text: TextStyleRange.plain(message.text, message.formatting), attachments: message.attachments),
                                    id: message.id, lastUpdateMicros: message.lastUpdateMicros ?? Int64((message.createdAt.timeIntervalSince1970 * 1_000_000).rounded()))
        forward.forwardedFrom = conversations.first { $0.id == message.conversationID }?.name ?? "a conversation"
        forward.media = message.attachments.first { $0.kind == .image || $0.kind == .video }
        quoting[key(destination, nil)] = forward
    }
    func delete(_ message: Message) async {
        do { try await backend.delete(message.id) } catch { report(error) }
    }
    /// `custom`: a custom emoji picked for the reaction; a pill's own custom emoji goes back whole.
    func react(_ emoji: String, custom: CustomEmoji? = nil, to message: Message) async {
        let existing = message.reactions.first { $0.emoji == emoji }
        let present = !(existing?.people.contains(me.id) ?? false)
        do { try await backend.setReaction(emoji, custom: existing?.custom ?? custom, on: message.id, present: present) } catch { report(error) }
    }
    /// Errors stay with the caller: a missing thumbnail shouldn't raise the store-wide error.
    /// A file not sent yet (the local echo) is read from disk.
    func attachmentData(_ attachment: Attachment, thumbnail: Bool) async throws -> Data {
        if let file = attachment.url, file.isFileURL { return try await Task.detached { try Data(contentsOf: file, options: .mappedIfSafe) }.value }
        return try await backend.attachmentData(attachment, thumbnail: thumbnail)
    }
    /// Messages in this timeline still uploading their files; the composer says so.
    func uploading(_ conversation: String, thread: String? = nil) -> Int {
        timeline(conversation, thread: thread).filter { $0.delivery == .pending && $0.attachments.contains { $0.isLocalFile && $0.uploadToken == nil } }.count
    }
    func markRead(_ id: String) async {
        notifier?.clear(conversation: id)
        // In the background, and tried again on the next visit: a refusal is for the log, not an alert.
        do { try await backend.markRead(id) } catch { log.error("mark read failed: \(String(describing: error), privacy: .public)") }
    }
    func setPinned(_ pinned: Bool, _ id: ConversationID) async {
        await change(id, \.pinned, to: pinned) { try await self.backend.setPinned(pinned, conversation: id) }
    }
    func setMuted(_ muted: Bool, _ id: ConversationID) async {
        await change(id, \.muted, to: muted) { try await self.backend.setMuted(muted, conversation: id) }
    }
    func setNotificationLevel(_ level: NotificationLevel, _ id: ConversationID) async {
        guard let room = conversations.first(where: { $0.id == id }) else { return }
        await change(id, \.notificationLevel, to: level) { try await self.backend.setNotificationLevel(level, muted: room.muted, conversation: id) }
    }
    func markUnread(_ id: ConversationID) async {
        guard let room = conversations.first(where: { $0.id == id }) else { return }
        await change(id, \.unread, to: max(room.unread, 1)) { try await self.backend.markUnread(id) }
    }
    /// Shown at once and sent; a refusal puts back only this field (others may have changed meanwhile) and says why.
    private func change<Value>(_ id: ConversationID, _ field: WritableKeyPath<Conversation, Value>, to value: Value,
                               send: () async throws -> Void) async {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        let before = conversations[i][keyPath: field]
        conversations[i][keyPath: field] = value; persist()
        do { try await send() } catch {
            if let i = conversations.firstIndex(where: { $0.id == id }) { conversations[i][keyPath: field] = before }
            report(error); persist()
        }
    }
    /// Gone from the sidebar at once; a refusal puts it back where it was.
    func leave(_ id: ConversationID) async {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let room = conversations[index]
        apply(.conversationRemoved(id))
        do { try await backend.leave(id) } catch {
            if !conversations.contains(where: { $0.id == id }) { conversations.insert(room, at: min(index, conversations.count)) }
            report(error); persist()
        }
    }
    /// A shortcut's messages, newest first; Starred drops a message as soon as it is unstarred.
    func shortcutMessages(_ shortcut: Shortcut) -> [Message] {
        (shortcutLists[shortcut] ?? []).filter { shortcut != .starred || $0.starred }
    }
    /// Shows a sidebar shortcut in place of the conversation, freshly loaded.
    func openShortcut(_ shortcut: Shortcut, recording: Bool = true) async {
        if recording { visit(.shortcut(shortcut)) }
        endMainWindowEdits()
        self.shortcut = shortcut; threadID = nil; info = false
        shortcutCursors[shortcut] = nil
        await loadShortcut(shortcut)
    }
    /// The first page, or (`more`) the next one while the server has more. One request at a time per shortcut.
    func loadShortcut(_ shortcut: Shortcut, more: Bool = false) async {
        let scope = "shortcut/\(shortcut.rawValue)"
        guard shortcut != .home else { return }   // built from the conversations and messages already held; see `homeRows`
        guard shortcut != .drafts else { return }   // the composers' drafts; see `draftList`
        guard !loading.contains(scope), !more || shortcutCursors[shortcut] != nil else { return }
        loading.insert(scope); defer { loading.remove(scope) }
        do {
            let page = try await backend.shortcut(shortcut, cursor: more ? shortcutCursors[shortcut] : nil)
            let known = more ? shortcutLists[shortcut] ?? [] : [], ids = Set(known.map(\.id))
            shortcutLists[shortcut] = known + page.messages.filter { !ids.contains($0.id) }
            shortcutCursors[shortcut] = page.cursor
        } catch { report(error) }
    }
    /// Home, as Google Chat's: the conversations with activity, each with its newest timeline message held, and the threads
    /// it lists, each with its newest reply; most recent first. A conversation is ordered by the later of the server's
    /// activity time and that message, so a message pushed since moves it up. `unreadOnly` and `threadsOnly` are web's
    /// "Unread" switch and "Thread" filter.
    func homeRows(unreadOnly: Bool = false, threadsOnly: Bool = false) -> [HomeRow] {
        var newest: [ConversationID: Message] = [:]
        for message in messages where !message.isSystem && message.threadID == nil && newest[message.conversationID].map({ message.createdAt > $0.createdAt }) ?? true {
            newest[message.conversationID] = message
        }
        let rooms = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let threads = homeThreads.compactMap { thread in rooms[thread.conversationID].map { HomeRow(room: $0, last: thread.latest, thread: thread, time: thread.time) } }
        let heads = Set(homeThreads.map(\.id))
        let roomRows = threadsOnly ? [] : conversations.compactMap { room -> HomeRow? in
            // As Google Chat: a conversation whose newest message starts a thread shown here appears only as that thread.
            if let last = newest[room.id], heads.contains(last.id) { return nil }
            let time = max(room.activity ?? .distantPast, newest[room.id]?.createdAt ?? .distantPast)
            return time == .distantPast ? nil : HomeRow(room: room, last: newest[room.id], time: time)
        }
        return (roomRows + threads).filter { !unreadOnly || $0.unread }.enumerated()
            .sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time > $1.element.time }.map(\.element)
    }
    /// A Home thread row: Home stays on screen and the thread opens in the thread pane beside it, at its newest reply.
    /// The conversation itself is not opened or marked read.
    // ponytail: the thread is read only here; the server's topic read state is not written (set_topic_unread_timestamp-style).
    func openHomeThread(_ thread: HomeThread) async {
        endMainWindowEdits()
        shortcut = .home; selectedID = thread.conversationID; info = false
        if let i = homeThreads.firstIndex(where: { $0.id == thread.id }) { homeThreads[i].unread = false }
        await openThread(thread.id, in: thread.conversationID)
        highlightedID = thread.latest.id
        await watchOpen()
    }
    /// A Home row's newest page, when the server reports activity after the newest message held (or none is held).
    /// Waits for the account: before connecting, Home lists the cached conversations, which may be another account's.
    func loadPreview(_ id: ConversationID) async {
        guard !me.id.isEmpty, let room = conversations.first(where: { $0.id == id }) else { return }
        let last = messages.lazy.filter { $0.conversationID == id && !$0.isSystem }.map(\.createdAt).max()
        // A second of slack: the server's sort time can trail the message's own time by a little.
        if let last, (room.activity ?? .distantPast) <= last.addingTimeInterval(1) { return }
        await load(id, quietly: true)
    }
    /// A shortcut's message in its conversation (and thread), highlighted.
    func showInChat(_ message: Message) async {
        shortcut = nil
        guard conversations.contains(where: { $0.id == message.conversationID }) else { await jump(message); return }
        await select(message.conversationID)
        await show(message.id, in: message.conversationID)
    }
    /// Starred or unstarred everywhere it shows at once; a refusal puts it back and says why.
    func setStarred(_ starred: Bool, _ message: Message) async {
        func mark(_ value: Bool) {
            for i in messages.indices where messages[i].id == message.id { messages[i].starred = value }
            for (key, list) in shortcutLists { shortcutLists[key] = list.map { var m = $0; if m.id == message.id { m.starred = value }; return m } }
            if value, let list = shortcutLists[.starred], !list.contains(where: { $0.id == message.id }) {
                var added = message; added.starred = true
                shortcutLists[.starred] = (list + [added]).sorted { $0.createdAt > $1.createdAt }
            }
        }
        mark(starred)
        do { try await backend.setStarred(starred, on: message.id) } catch { mark(!starred); report(error) }
        persist()
    }
    func search(_ query: String) async {
        searchGeneration += 1
        let generation = searchGeneration
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { searchResults = []; return }
        do {
            let page = try await backend.searchMessages(query, cursor: nil)
            if generation == searchGeneration { searchResults = page.messages }
        } catch { if generation == searchGeneration { report(error) } }
    }
    /// File › New Chat asks the main window to open its palette.
    var newChatRequests = 0
    var forwarding: Message?   // Forward…: the message whose destination is being picked
    // New conversations. Errors stay with the caller, which shows them where the search or action happened.
    func searchPeople(_ query: String) async throws -> [Person] { try await backend.searchPeople(query) }
    func browseSpaces(_ query: String) async throws -> [SpaceListing] { try await backend.browseSpaces(query) }
    /// Opens the DM with exactly these people: the sidebar's when there is one, else the server's (found or created).
    func message(_ people: [Person]) async throws {
        let ids = Set(people.map(\.id)).subtracting([me.id])
        guard !ids.isEmpty else { return }
        if let room = conversations.first(where: { $0.kind != .space && Set($0.members.map(\.id)).subtracting([me.id]) == ids }) {
            await select(room.id)
            return
        }
        await open(try await backend.directMessage(with: people.map(\.id).filter { $0 != me.id }))
    }
    /// Joins a space, or just opens it when it is already in the sidebar.
    func join(_ space: SpaceListing) async throws {
        if conversations.contains(where: { $0.id == space.id }) { await select(space.id); return }
        await open(try await backend.join(space))
    }
    private func open(_ room: Conversation) async {
        apply(.conversationUpserted(room))
        await select(room.id)
    }
    func jump(_ message: Message) async {
        if !conversations.contains(where: { $0.id == message.conversationID }) {
            // A search hit from a conversation the sidebar doesn't list yet.
            conversations.append(Conversation(id: message.conversationID, name: "Conversation", kind: .group, members: []))
        }
        await select(message.conversationID)
        if message.threadID != nil { await openThread(message) }
        upsert(message); highlightedID = message.id
    }
    /// Saves at most once every two seconds, with whatever is current by then: a busy room never starves the save.
    private func persist() {
        guard cache != nil, cacheTask == nil else { return }
        cacheTask = Task {
            try? await Task.sleep(for: .seconds(2))
            cacheTask = nil
            guard !Task.isCancelled else { return }
            await save()
        }
    }
    private func snapshot() -> LaunchSnapshot {
        let grouped = Dictionary(grouping: messages.filter { $0.delivery != .pending }, by: { key($0.conversationID, $0.threadID) })
        return LaunchSnapshot(accountID: me.id.isEmpty ? cachedAccountID : me.id, conversations: conversations,
                              messages: grouped.values.flatMap { Array($0.sorted { $0.createdAt < $1.createdAt }.suffix(50)) },
                              selectedID: selectedID, drafts: drafts, draftFormatting: draftFormatting, draftEdits: draftEdits, serverDrafts: serverDrafts,
                              homeThreads: homeThreads)
    }
    private func save() async {
        guard let cache else { return }
        let snapshot = snapshot()
        do { try await Task.detached { try cache.save(snapshot) }.value }
        catch { self.error = "Couldn’t save the launch cache: \(error.localizedDescription)" }
    }
    /// At quit: the pending save can't wait for its delay.
    func flush() {
        cacheTask?.cancel(); cacheTask = nil
        guard let cache else { return }
        try? cache.save(snapshot())
    }
}
