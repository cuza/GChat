import AppKit
import Intents
import Security
import UserNotifications
import os

private let log = Logger(subsystem: "dev.cuza.Parley", category: "notifications")

/// When a conversation notifies me, as Google Chat stores it per person (the same setting web and mobile Chat show).
enum NotificationLevel: String, Codable, Sendable {
    case always                // every message: a DM's "All new messages", an older space's "Notify always"
    case all                   // every message, every thread followed: a space's "All new messages"
    case main                  // new threads, replies in threads I follow, @mentions
    case forYouAndNewThreads   // older spaces: "For you" plus new threads
    case forYou                // @mentions and replies in threads I follow
    case off                   // nothing, not even @mentions

    var title: String {
        switch self {
        case .always, .all: "All new messages"
        case .main: "Main conversations"
        case .forYouAndNewThreads: "For you and new threads"
        case .forYou: "For you"
        case .off: "Don't notify"
        }
    }
    /// What the web offers: spaces get four levels, DMs notify or don't. A level set elsewhere stays pickable.
    static func choices(for kind: ConversationKind, current: NotificationLevel?) -> [NotificationLevel] {
        var choices: [NotificationLevel] = kind == .space ? [.all, .main, .forYou, .off] : [.always, .off]
        if current == .always, let i = choices.firstIndex(of: .all) { choices[i] = .always }
        if let current, !choices.contains(current) { choices.append(current) }
        return choices
    }
    /// A message I didn't send: `head` starts a thread (every top-level message does), `followed` is a reply in a thread
    /// I follow, `mentioned` names me or @all.
    func notifies(head: Bool, followed: Bool, mentioned: Bool) -> Bool {
        switch self {
        case .always, .all: true
        case .main, .forYouAndNewThreads: head || followed || mentioned
        case .forYou: followed || mentioned
        case .off: false
        }
    }
}

/// Settings ▸ Notifications, stored with @AppStorage under this key. Which messages notify is each conversation's level.
/// The sound a notification plays: macOS's default (played by macOS, its Focus rules and all), none, or a sound installed
/// on the Mac (by file name, from its Sounds folders). macOS plays only its default for an app and swaps any other sound
/// for it, so a named sound's banner goes silent and Parley plays the sound itself, as Slack plays its own.
enum NotificationSound: Hashable, Sendable {
    case standard, none, named(String)
    static let key = "messageSound"
    /// The Mac's Sounds folders, as System Settings ▸ Sound lists them: the user's, the Mac's, and macOS's.
    static let folders = [URL.libraryDirectory, URL(filePath: "/Library"), URL(filePath: "/System/Library")].map { $0.appending(path: "Sounds") }
    var stored: String { switch self { case .standard: "default"; case .none: "none"; case .named(let file): file } }
    /// A stored choice; Parley's own sounds before (Duet, Drop, Rise) are gone, so they are the default.
    init(stored: String?) {
        switch stored {
        case "none": self = .none
        case let file? where file.contains("."): self = .named(file)
        default: self = .standard
        }
    }
    var name: String {
        switch self { case .standard: "Default"; case .none: "None"; case .named(let file): (file as NSString).deletingPathExtension }
    }
    static var current: NotificationSound { NotificationSound(stored: UserDefaults.standard.string(forKey: key)) }
    /// Default and None, then each sound the folders hold (the formats a notification can play), by name, once each.
    static func available(in folders: [URL] = folders) -> [NotificationSound] {
        let files = folders.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] }
            .filter { ["aiff", "aif", "caf", "wav"].contains(($0 as NSString).pathExtension.lowercased()) }
        var seen = Set<String>()
        let named = files.filter { seen.insert(($0 as NSString).deletingPathExtension).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return [.standard, .none] + named.map(NotificationSound.named)
    }
    var notificationSound: UNNotificationSound? { self == .standard ? .default : nil }
    var playedByParley: Bool { if case .named = self { true } else { false } }
    /// The sound to hear it in Settings, as System Settings plays an alert sound; none for the default.
    @MainActor var preview: NSSound? {
        guard case .named(let file) = self else { return nil }
        return Self.folders.lazy.map { $0.appending(path: file) }.first { FileManager.default.fileExists(atPath: $0.path) }
            .flatMap { NSSound(contentsOf: $0, byReference: true) }
    }
}

/// Whether Parley plays a named sound for a banner just posted: whenever sounds are allowed for Parley in System
/// Settings, during a Focus too, as Slack plays its own. macOS's default follows macOS's rules alone.
enum NotificationSoundPolicy {
    static func plays(_ sound: NotificationSound, soundsAllowed: Bool) -> Bool { sound.playedByParley && soundsAllowed }
}

struct NotificationSettings: Equatable, Sendable {
    static let enabledKey = "notificationsEnabled"
    // ponytail: one switch covers messages and reactions to mine; add a per-kind toggle if reaction banners prove noisy.
    var enabled = true
    static var current: NotificationSettings {
        NotificationSettings(enabled: UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true)
    }
}

/// What a banner shows and where clicking it leads. `id` is the message id, so a repeat replaces rather than stacks.
struct ChatNotification: Equatable, Sendable {
    var id: MessageID
    var title: String
    var subtitle: String
    var body: String
    var conversationID: ConversationID
    var threadID: ThreadID?
    var sender: Person
    /// The group DM's or space's name; nil for a 1:1 DM.
    var group: String?
    /// The sender's photo (a 1:1 DM without one falls back to the conversation's), else their initials.
    var picture: Picture
    /// An incoming call: the notification says so and offers to join the meeting or decline.
    var isCall = false
    var join: URL? = nil
    func incomingCall(join url: URL?) -> ChatNotification { var call = self; call.isCall = true; call.join = url; call.body = "Calling you"; return call }

    struct Picture: Equatable, Sendable {
        var name: String
        var url: URL? = nil
    }
}

enum NotificationPolicy {
    /// A pushed message's notification, or nil when it shouldn't interrupt: own, muted (even an @mention), edited, older than
    /// two minutes (an update to a message not loaded here), a text-less system event, below the conversation's level
    /// (unknown counts as every message), or already on screen. `threadFollowed`: the reply's thread is one I follow.
    static func notification(for message: Message, in conversation: Conversation?, me: String, openConversation: ConversationID?,
                             openThread: ThreadID?, appActive: Bool, settings: NotificationSettings, threadFollowed: Bool = false,
                             now: Date = .now) -> ChatNotification? {
        guard settings.enabled, !message.isSystem, message.sender.id != me, !(conversation?.muted ?? false), !message.edited,
              message.createdAt > now.addingTimeInterval(-120), !message.text.isEmpty || !message.attachments.isEmpty,
              conversation?.notificationLevel?.notifies(head: message.threadID == nil, followed: message.threadID != nil && threadFollowed,
                                                        mentioned: mentions(message, me: me)) ?? true else { return nil }
        let direct = conversation?.kind == .direct
        let onScreen = appActive && message.conversationID == openConversation && (message.threadID == nil || message.threadID == openThread)
        guard !onScreen else { return nil }
        let gif = message.attachments.first.map { $0.contentType == "image/gif" || $0.url?.pathExtension.lowercased() == "gif" } ?? false
        return ChatNotification(id: message.id, title: direct || conversation == nil ? message.sender.name : conversation!.name,
                                subtitle: direct || conversation == nil ? "" : message.sender.name,
                                body: !message.text.isEmpty ? TextStyleRange.plain(message.text, message.formatting) : gif ? "GIF" : message.attachments.first?.kind == .voice ? "Voice message"
                                    : message.attachments.first?.kind == .call ? message.attachments[0].name : "Sent an attachment",
                                conversationID: message.conversationID, threadID: message.threadID, sender: message.sender,
                                group: direct ? nil : conversation?.name,
                                picture: .init(name: message.sender.name, url: message.sender.avatarURL ?? (direct ? conversation?.avatarURL : nil)))
    }
    /// Whether a message is someone's call to me, just started in a DM: Google posts it as the call rings. Not a huddle.
    static func isIncomingCall(_ message: Message, in conversation: Conversation?, me: String, now: Date = .now) -> Bool {
        guard message.sender.id != me, conversation?.kind == .direct, message.createdAt > now.addingTimeInterval(-60),
              let call = message.attachments.first(where: { $0.kind == .call }) else { return false }
        return call.call == .started && call.huddle != true
    }
    /// Someone else's reaction to a message I sent, as Google Chat words it, or nil when it shouldn't interrupt: notifications
    /// off, the conversation muted or set to "Don't notify", or the message on screen. Removals and repeats are the caller's.
    static func reaction(_ emoji: String, by reactor: Person, to message: Message, in conversation: Conversation?, me: String,
                         openConversation: ConversationID?, openThread: ThreadID?, appActive: Bool,
                         settings: NotificationSettings) -> ChatNotification? {
        guard settings.enabled, message.sender.id == me, reactor.id != me, !(conversation?.muted ?? false),
              conversation?.notificationLevel != .off else { return nil }
        let onScreen = appActive && message.conversationID == openConversation && (message.threadID == nil || message.threadID == openThread)
        guard !onScreen else { return nil }
        let direct = conversation?.kind == .direct
        let text = TextStyleRange.plain(message.text, message.formatting).trimmingCharacters(in: .whitespacesAndNewlines)
        let quote = text.count > 100 ? String(text.prefix(100)) + "…" : text
        return ChatNotification(id: "\(message.id)#\(reactor.id)#\(emoji)", title: direct || conversation == nil ? reactor.name : conversation!.name,
                                subtitle: direct || conversation == nil ? "" : reactor.name,
                                body: quote.isEmpty ? "Reacted \(emoji) to your message" : "Reacted \(emoji) to: “\(quote)”",
                                conversationID: message.conversationID, threadID: message.threadID, sender: reactor,
                                group: direct ? nil : conversation?.name,
                                picture: .init(name: reactor.name, url: reactor.avatarURL ?? (direct ? conversation?.avatarURL : nil)))
    }
    /// Names me, or everyone with @all.
    static func mentions(_ message: Message, me: String) -> Bool {
        message.formatting.contains { $0.style == .mention(userID: me) || $0.style == .mention(userID: TextStyleRange.everyone) }
    }
}

/// Who sent it, on the banner: a communication notification (an INSendMessageIntent restyles the banner with the sender's
/// photo and name, and lets Focus match the sender), which needs the Communication Notifications entitlement. Reactions go the
/// same way, since they come from a person too. If the system refuses, the banner stays plain: no attached picture, whose
/// large preview broke the banner's Reply field.
@MainActor enum NotificationImage {
    static let px = 128
    static let entitlement = "com.apple.developer.usernotifications.communication"
    static let hasEntitlement: Bool = SecTaskCreateFromSelf(nil)
        .flatMap { SecTaskCopyValueForEntitlement($0, entitlement as CFString, nil) as? Bool } ?? false

    /// The banner with sender imagery: `communicate` makes it a communication notification; if that throws, `base` as is.
    static func content(for note: ChatNotification, base: UNMutableNotificationContent,
                        load: @escaping @Sendable @MainActor (URL) async -> NSImage? = { await RemoteImage.image($0, px: px) },
                        communicate: @MainActor (INSendMessageIntent, UNNotificationContent) async throws -> UNNotificationContent
                            = donateAndUpdate) async -> UNNotificationContent {
        let picture = await png(for: note.picture, load: load)
        do { return try await communicate(intent(for: note, image: picture), base) }
        catch {
            log.error("communication notification refused: \(error.localizedDescription, privacy: .public)")
            return base
        }
    }

    /// Donates the incoming message (best effort), then lets the system restyle the banner. Throws without the entitlement.
    static func donateAndUpdate(_ intent: INSendMessageIntent, _ content: UNNotificationContent) async throws -> UNNotificationContent {
        guard hasEntitlement else { throw CocoaError(.featureUnsupported) }
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        do { try await interaction.donate() }
        catch { log.error("donating the message failed: \(error.localizedDescription, privacy: .public)") }
        return try content.updating(from: intent)
    }

    /// The sender, and for a group DM or space its name and a second recipient, which is what makes the system show a group.
    /// The sender's handle is their email when known: the system matches it against Contacts for Focus "Allowed People".
    /// macOS has no separate group image (`setImage(_:forParameterNamed:)` is unavailable), so a space shows the sender's photo.
    /// The text stays in the banner's body, not the intent's `content`.
    static func intent(for note: ChatNotification, image: Data) -> INSendMessageIntent {
        let photo = INImage(imageData: image)
        let handle = note.sender.email.map { INPersonHandle(value: $0, type: .emailAddress) } ?? INPersonHandle(value: note.sender.id, type: .unknown)
        let sender = INPerson(personHandle: handle, nameComponents: nil, displayName: note.sender.name, image: photo,
                              contactIdentifier: nil, customIdentifier: note.sender.id, isMe: false)
        let me = INPerson(personHandle: INPersonHandle(value: "me", type: .unknown), nameComponents: nil, displayName: nil,
                          image: nil, contactIdentifier: nil, customIdentifier: nil, isMe: true)
        let intent = INSendMessageIntent(recipients: note.group == nil ? nil : [me, sender], outgoingMessageType: .outgoingMessageText,
                                         content: nil, speakableGroupName: note.group.map { INSpeakableString(spokenPhrase: $0) },
                                         conversationIdentifier: note.conversationID, serviceName: nil, sender: sender, attachments: nil)
        return intent
    }

    /// The picture as PNG: the photo if it loads within `timeout`, else initials as `Avatar` draws them.
    static func png(for picture: ChatNotification.Picture, timeout: Duration = .seconds(1.5),
                    load: @escaping @Sendable @MainActor (URL) async -> NSImage? = { await RemoteImage.image($0, px: px) }) async -> Data {
        if let url = picture.url {
            // The loader stops on cancellation (URLSession does), so the timer bounds the wait.
            let loading = Task { await load(url) }
            let timer = Task { try await Task.sleep(for: timeout); loading.cancel() }
            let image = await loading.value
            timer.cancel()
            if let image { return draw { image.draw(in: $0) } }
        }
        return render(picture)
    }

    static func render(_ picture: ChatNotification.Picture) -> Data {
        draw { rect in
            NSColor(hue: Avatar.hue(picture.name), saturation: 0.35, brightness: 0.65, alpha: 1).setFill()
            rect.fill()
            let text = NSAttributedString(string: Avatar.initials(picture.name), attributes: [
                .font: NSFont.systemFont(ofSize: rect.width * 0.4, weight: .semibold), .foregroundColor: NSColor.white])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
    }

    /// A `px`-square PNG clipped to a circle, like `Avatar` draws a person.
    private static func draw(_ body: (NSRect) -> Void) -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return Data() }
        let rect = NSRect(x: 0, y: 0, width: px, height: px), radius = rect.width / 2
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
        body(rect)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }
}

/// Where ChatStore posts notifications; tests record instead of showing banners.
@MainActor protocol Notifier: AnyObject {
    func post(_ notification: ChatNotification)
    /// Removes the conversation's delivered notifications (it was read).
    func clear(conversation: ConversationID)
}

/// UNUserNotificationCenter: banners grouped per conversation, a Reply text field, and clicks routed back to the store.
@MainActor final class SystemNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate {
    static let category = "message", replyAction = "reply"
    static let callCategory = "call", joinAction = "join", declineAction = "decline"
    private let store: ChatStore
    private var center: UNUserNotificationCenter { .current() }

    /// Set up before launch finishes so a click that launched the app still reaches the delegate.
    init(store: ChatStore) {
        self.store = store
        super.init()
        center.delegate = self
        let reply = UNTextInputNotificationAction(identifier: Self.replyAction, title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        // An incoming call, as FaceTime offers one: Join opens the meeting; Decline dismisses it (Google isn't told).
        let join = UNNotificationAction(identifier: Self.joinAction, title: "Join", options: [])
        let decline = UNNotificationAction(identifier: Self.declineAction, title: "Decline", options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [reply], intentIdentifiers: []),
                                          UNNotificationCategory(identifier: Self.callCategory, actions: [join, decline], intentIdentifiers: [])])
        store.notifier = self
    }
    /// Asks once the app is running: asked during launch, macOS showed no prompt and nothing was ever delivered.
    /// The system asks only the first time; later calls return the saved answer.
    @discardableResult
    static func requestAuthorization() async -> UNAuthorizationStatus {
        let center = UNUserNotificationCenter.current()
        do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
        catch { log.error("notification authorization failed: \(error.localizedDescription, privacy: .public)") }
        return await center.notificationSettings().authorizationStatus
    }
    func post(_ notification: ChatNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        content.sound = NotificationSound.current.notificationSound
        content.threadIdentifier = notification.conversationID
        content.categoryIdentifier = notification.isCall ? Self.callCategory : Self.category
        content.userInfo = ["conversation": notification.conversationID, "thread": notification.threadID ?? "",
                            "join": notification.join?.absoluteString ?? ""]
        Task {
            let restyled = await NotificationImage.content(for: notification, base: content)
            let shown = (restyled.mutableCopy() as? UNMutableNotificationContent) ?? content
            shown.sound = content.sound   // the restyling would give a silent banner macOS's default sound
            do {
                try await center.add(UNNotificationRequest(identifier: notification.id, content: shown, trigger: nil))
                log.notice("banner posted")
                await Self.playSound()
            }
            catch { log.error("posting a notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
    /// While Parley is in front: the banner, with macOS's sound only when macOS plays it (Default).
    nonisolated static func presentation(_ sound: NotificationSound) -> UNNotificationPresentationOptions {
        sound == .standard ? [.banner, .list, .sound] : [.banner, .list]
    }
    private static var playing: NSSound?
    /// A named sound, for a banner just posted, when NotificationSoundPolicy says so.
    private static func playSound() async {
        let sound = NotificationSound.current
        guard sound.playedByParley else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard NotificationSoundPolicy.plays(sound, soundsAllowed: settings.soundSetting == .enabled) else { return }
        playing?.stop()
        playing = sound.preview
        playing?.play()
    }
    func clear(conversation: ConversationID) {
        Task {
            let ids = await center.deliveredNotifications().filter { $0.request.content.threadIdentifier == conversation }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }
    // The store already skipped what is on screen, so anything posted shows even while the app is active.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        Self.presentation(NotificationSound.current)
    }
    // Async delegate methods arrive off the main thread: read the non-Sendable response here, then hop to the store.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let conversation = info["conversation"] as? String else { return }
        let thread = (info["thread"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let action = response.actionIdentifier, text = (response as? UNTextInputNotificationResponse)?.userText
        let join = (info["join"] as? String).flatMap(URL.init(string:))
        await route(action: action, text: text, conversation: conversation, thread: thread, join: join)
    }
    private func route(action: String, text: String?, conversation: ConversationID, thread: ThreadID?, join: URL?) async {
        switch action {
        case Self.replyAction: await store.reply(text ?? "", conversation: conversation, thread: thread)
        case Self.joinAction: if let join { NSWorkspace.shared.open(join) }
        case UNNotificationDefaultActionIdentifier:
            NSApplication.shared.activate()
            await store.open(conversation: conversation, thread: thread)
        default: break
        }
    }
}
