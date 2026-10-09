import AppKit
import Intents
import Testing
import UserNotifications
@testable import Parley

@MainActor
struct NotificationImageryTests {
    let maria = Person(id: "maria", name: "Maria Chen", avatarURL: URL(string: "https://lh3.googleusercontent.com/a/x"))
    func note(space: Bool, sender: Person? = nil) -> ChatNotification {
        let sender = sender ?? maria
        return ChatNotification(id: "m1", title: space ? "Design studio" : sender.name, subtitle: space ? sender.name : "", body: "Lunch?",
                                conversationID: "space/a", threadID: nil, sender: sender, group: space ? "Design studio" : nil,
                                picture: .init(name: sender.name, url: sender.avatarURL))
    }
    func isPNG(_ data: Data) -> Bool { data.count > 8 && data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) }

    @Test func policyCarriesTheSenderAndTheirPhotoEvenInASpace() throws {
        var space = Conversation(id: "space/a", name: "Design studio", kind: .space, members: [])
        space.emoji = "🎨"
        let message = Message(id: "m1", conversationID: "space/a", sender: maria, text: "hi", createdAt: .now)
        let spaceNote = try #require(NotificationPolicy.notification(for: message, in: space, me: "me", openConversation: nil,
                                                                     openThread: nil, appActive: false, settings: .init()))
        #expect(spaceNote.sender == maria && spaceNote.group == "Design studio")
        #expect(spaceNote.picture == .init(name: "Maria Chen", url: maria.avatarURL))
        let dm = Conversation(id: "space/a", name: "Maria Chen", kind: .direct, members: [])
        let dmNote = try #require(NotificationPolicy.notification(for: message, in: dm, me: "me", openConversation: nil,
                                                                  openThread: nil, appActive: false, settings: .init()))
        #expect(dmNote.group == nil && dmNote.picture == .init(name: "Maria Chen", url: maria.avatarURL))
    }
    @Test func initialsRenderToPNG() {
        #expect(isPNG(NotificationImage.render(.init(name: "Maria Chen"))))
    }
    @Test func failedOrSlowPhotoFallsBackToInitials() async {
        let url = URL(string: "https://example.com/a.png")!
        #expect(isPNG(await NotificationImage.png(for: .init(name: "Maria Chen", url: url)) { _ in nil }))
        let start = ContinuousClock.now
        let slow = await NotificationImage.png(for: .init(name: "Maria Chen", url: url), timeout: .milliseconds(50)) { _ in
            try? await Task.sleep(for: .seconds(5))
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        #expect(isPNG(slow) && ContinuousClock.now - start < .seconds(2))
    }
    @Test func intentCarriesSenderConversationAndGroup() {
        let png = NotificationImage.render(.init(name: "Maria Chen"))
        let direct = NotificationImage.intent(for: note(space: false), image: png)
        #expect(direct.sender?.displayName == "Maria Chen" && direct.sender?.personHandle?.value == "maria")
        #expect(direct.sender?.personHandle?.type == .unknown && direct.sender?.customIdentifier == "maria")
        #expect(direct.sender?.isMe == false && direct.sender?.contactIdentifier == nil)
        #expect(direct.sender?.image != nil && direct.conversationIdentifier == "space/a" && direct.speakableGroupName == nil)
        #expect(direct.recipients == nil && direct.content == nil)
        let space = NotificationImage.intent(for: note(space: true), image: png)
        #expect(space.speakableGroupName?.spokenPhrase == "Design studio" && space.conversationIdentifier == "space/a")
        #expect(space.content == nil && (space.recipients?.count ?? 0) > 1)
        #expect(space.recipients?.contains { $0.isMe } == true && space.recipients?.contains { $0.customIdentifier == "maria" } == true)
    }
    /// Focus "Allowed People" matches the sender's email against Contacts.
    @Test func intentSenderIsAnEmailHandleWhenTheEmailIsKnown() {
        let withEmail = Person(id: "maria", name: "Maria Chen", email: "maria@example.com")
        let intent = NotificationImage.intent(for: note(space: false, sender: withEmail), image: NotificationImage.render(.init(name: "Maria Chen")))
        #expect(intent.sender?.personHandle?.value == "maria@example.com" && intent.sender?.personHandle?.type == .emailAddress)
        #expect(intent.sender?.customIdentifier == "maria")
    }
    @Test func communicationContentIsUsedWhenTheSystemAcceptsIt() async {
        let content = await NotificationImage.content(for: note(space: false), base: UNMutableNotificationContent(),
                                                      load: { _ in nil }) { _, base in
            let updated = base.mutableCopy() as! UNMutableNotificationContent
            updated.title = "from intent"
            return updated
        }
        #expect(content.title == "from intent" && content.attachments.isEmpty)
    }
    /// No attachment either way: a big picture on the banner broke its Reply field.
    @Test func plainContentIsUsedWhenTheSystemRefusesTheIntent() async {
        let base = UNMutableNotificationContent()
        base.title = "Maria Chen"
        let content = await NotificationImage.content(for: note(space: false), base: base, load: { _ in nil }) { _, _ in
            throw UNError(.notificationInvalidNoContent)
        }
        #expect(content.title == "Maria Chen" && content.attachments.isEmpty)
    }
}

struct NotificationPolicyTests {
    let maria = Person(id: "maria", name: "Maria Chen")
    let space = Conversation(id: "space/a", name: "Design studio", kind: .space, members: [])
    let dm = Conversation(id: "dm/b", name: "Maria Chen", kind: .direct, members: [])
    let now = Date(timeIntervalSince1970: 1_000_000)

    func decide(_ message: Message, in conversation: Conversation?, open: ConversationID? = nil, thread: ThreadID? = nil, active: Bool = false,
                settings: NotificationSettings = .init()) -> ChatNotification? {
        NotificationPolicy.notification(for: message, in: conversation, me: "me", openConversation: open, openThread: thread,
                                        appActive: active, settings: settings, now: now)
    }
    func message(_ text: String = "hi", in conversation: Conversation, thread: ThreadID? = nil, from sender: Person? = nil,
                 attachments: [Parley.Attachment] = [], formatting: [TextStyleRange] = []) -> Message {
        Message(id: "m1", conversationID: conversation.id, threadID: thread, sender: sender ?? maria, text: text, createdAt: now,
                attachments: attachments, formatting: formatting)
    }

    @Test func spaceMessageNamesTheSpaceAndTheSender() throws {
        let note = try #require(decide(message("Lunch?", in: space, thread: "t1"), in: space))
        #expect(note == ChatNotification(id: "m1", title: "Design studio", subtitle: "Maria Chen", body: "Lunch?",
                                         conversationID: "space/a", threadID: "t1", sender: maria, group: "Design studio",
                                         picture: .init(name: "Maria Chen")))
    }
    @Test func directMessageTitleIsTheSenderWithoutSubtitle() throws {
        let note = try #require(decide(message(in: dm), in: dm))
        #expect(note.title == "Maria Chen" && note.subtitle == "" && note.conversationID == "dm/b" && note.threadID == nil)
    }
    @Test func attachmentOnlyMessagesGetAPlaceholderBody() throws {
        let gif = Parley.Attachment(name: "gif", contentType: "image/gif", kind: .image)
        let file = Parley.Attachment(name: "a.pdf", kind: .file)
        #expect(decide(message("", in: dm, attachments: [gif]), in: dm)?.body == "GIF")
        #expect(decide(message("", in: dm, attachments: [file]), in: dm)?.body == "Sent an attachment")
    }
    @Test func skipsOwnMutedEmptyStaleAndEditedMessages() {
        var muted = space; muted.muted = true
        var edited = message(in: space); edited.edited = true
        var stale = message(in: space); stale.createdAt = now.addingTimeInterval(-600)
        #expect(decide(message(in: space, from: Person(id: "me", name: "Dave")), in: space) == nil)
        #expect(decide(message(in: muted), in: muted) == nil)
        #expect(decide(message("", in: space), in: space) == nil)   // a system event
        #expect(decide(edited, in: space) == nil)
        #expect(decide(stale, in: space) == nil)
    }
    @Test func skipsOnlyWhatIsOnScreen() {
        #expect(decide(message(in: space), in: space, open: "space/a", active: true) == nil)
        #expect(decide(message(in: space), in: space, open: "space/a", active: false) != nil)    // window in the background
        #expect(decide(message(in: space), in: space, open: "dm/b", active: true) != nil)        // another conversation
        #expect(decide(message(in: space, thread: "t1"), in: space, open: "space/a", active: true) != nil)               // thread not open
        #expect(decide(message(in: space, thread: "t1"), in: space, open: "space/a", thread: "t1", active: true) == nil)
    }
    @Test func theMasterSwitchSilencesEverything() {
        let mention = message("@Dave look", in: space, formatting: [TextStyleRange(style: .mention(userID: "me"), start: 0, length: 5)])
        #expect(decide(message(in: dm), in: dm, settings: NotificationSettings(enabled: false)) == nil)
        #expect(decide(mention, in: space, settings: NotificationSettings(enabled: false)) == nil)
        #expect(decide(mention, in: space) != nil)
    }
    @Test func unknownConversationFallsBackToTheSender() {
        #expect(decide(message(in: space), in: nil)?.title == "Maria Chen")
    }
    @Test func cachedMentionsWithoutAUserStillDecode() throws {
        let range = try JSONDecoder().decode(TextStyleRange.self, from: Data(#"{"style":{"mention":{}},"start":0,"length":1}"#.utf8))
        #expect(range.style == .mention(userID: nil))
    }
}

@MainActor
struct ReactionNotificationTests {
    let maria = Person(id: "maria", name: "Maria Chen")
    let space = Conversation(id: "space/a", name: "Design studio", kind: .space, members: [])
    func mine(_ text: String = "Lunch at noon?", in conversation: ConversationID = "space/a") -> Message {
        Message(id: "\(conversation)/t1/m1", conversationID: conversation, sender: Person(id: "me", name: "Me"), text: text)
    }
    func decide(_ emoji: String = "👍", by reactor: Person? = nil, to message: Message? = nil, in conversation: Conversation? = nil,
                open: ConversationID? = nil, active: Bool = true, settings: NotificationSettings = .init()) -> ChatNotification? {
        NotificationPolicy.reaction(emoji, by: reactor ?? maria, to: message ?? mine(), in: conversation ?? space, me: "me",
                                    openConversation: open, openThread: nil, appActive: active, settings: settings)
    }
    @Test func othersReactionToMyMessageIsWordedLikeGoogleChat() throws {
        let note = try #require(decide())
        #expect(note.title == "Design studio" && note.subtitle == "Maria Chen" && note.sender == maria)
        #expect(note.body == "Reacted 👍 to: “Lunch at noon?”")
        #expect(note.conversationID == "space/a" && note.id != mine().id)   // doesn't replace the message's own banner
        let dm = Conversation(id: "dm/b", name: "Maria Chen", kind: .direct, members: [])
        let dmNote = try #require(decide(":partyparrot:", to: mine(in: "dm/b"), in: dm))
        #expect(dmNote.title == "Maria Chen" && dmNote.subtitle == "" && dmNote.body == "Reacted :partyparrot: to: “Lunch at noon?”")
        #expect(decide(to: mine(String(repeating: "a", count: 150)))?.body == "Reacted 👍 to: “\(String(repeating: "a", count: 100))…”")
        #expect(decide(to: mine(""))?.body == "Reacted 👍 to your message")
    }
    @Test func quietCasesDoNotNotify() {
        var muted = space; muted.muted = true
        var off = space; off.notificationLevel = .off
        var forYou = space; forYou.notificationLevel = .forYou
        #expect(decide(by: Person(id: "me", name: "Me")) == nil)                                       // my own reaction
        #expect(decide(to: Message(id: "x", conversationID: "space/a", sender: maria, text: "hi")) == nil)   // someone else's message
        #expect(decide(in: muted) == nil && decide(in: off) == nil)
        #expect(decide(in: forYou) != nil)
        #expect(decide(settings: .init(enabled: false)) == nil)
        #expect(decide(open: "space/a") == nil)                                                      // on screen
        #expect(decide(open: "space/a", active: false) != nil)
    }
    @Test func storePostsALiveAddOnceAndIgnoresRemovals() async throws {
        let fake = FakeBackend(), notifier = RecordingNotifier()
        let store = ChatStore(backend: fake)
        store.notifier = notifier
        store.notificationSettings = { NotificationSettings() }
        store.isAppActive = { true }
        await store.start()
        let other = try #require(store.conversations.first { $0.id != store.selectedID && !$0.muted && $0.notificationLevel != .off })
        let message = Message(id: "\(other.id)/t9/m9", conversationID: other.id, sender: store.me, text: "shipped it")
        store.apply(.messageUpserted(message))
        store.apply(.reacted(message.id, emoji: "🎉", by: "maria", added: false))
        store.apply(.reacted(message.id, emoji: "🎉", by: "maria", added: true))
        store.apply(.reacted(message.id, emoji: "🎉", by: "maria", added: true))   // repeated
        store.apply(.reacted(message.id, emoji: "🎉", by: store.me.id, added: true))
        store.apply(.reacted("unknown/t/m", emoji: "🎉", by: "maria", added: true))
        #expect(notifier.posted.map(\.body) == ["Reacted 🎉 to: “shipped it”"])
        #expect(notifier.posted.first?.conversationID == other.id && notifier.posted.first?.sender.id == "maria")
    }
}

@MainActor final class RecordingNotifier: Notifier {
    var posted: [ChatNotification] = []
    var cleared: [ConversationID] = []
    func post(_ notification: ChatNotification) { posted.append(notification) }
    func clear(conversation: ConversationID) { cleared.append(conversation) }
}

@MainActor
struct ChatStoreNotificationTests {
    func started() async throws -> (ChatStore, RecordingNotifier, FakeBackend) {
        let fake = FakeBackend(), notifier = RecordingNotifier()
        let store = ChatStore(backend: fake)
        store.notifier = notifier
        store.notificationSettings = { NotificationSettings() }
        store.isAppActive = { true }
        await store.start()
        notifier.cleared.removeAll()
        return (store, notifier, fake)
    }
    @Test func pushedMessagesPostOnceAndOnlyWhenOffScreen() async throws {
        let (store, notifier, _) = try await started()
        let selected = try #require(store.selectedID)
        let other = try #require(store.conversations.first { $0.id != selected && !$0.muted })
        let maria = Person(id: "maria", name: "Maria Chen")
        let incoming = Message(id: "push-1", conversationID: other.id, sender: maria, text: "hi")
        store.apply(.messageUpserted(incoming))
        store.apply(.messageUpserted(incoming))                                                     // echo / edit of a known message
        store.apply(.messageUpserted(Message(id: "push-2", conversationID: selected, sender: maria, text: "here")))
        #expect(notifier.posted.map(\.id) == ["push-1"])
        #expect(notifier.posted.first?.conversationID == other.id)
    }
    @Test func historyLoadsDoNotNotify() async throws {
        let (store, notifier, _) = try await started()
        let other = try #require(store.conversations.first { $0.id != store.selectedID })
        await store.select(other.id)
        #expect(notifier.posted.isEmpty)
    }
    @Test func readingAConversationClearsItsNotifications() async throws {
        let (store, notifier, _) = try await started()
        await store.select("alex")
        store.apply(.readStateChanged("maria", unread: 0))   // read on another device
        #expect(notifier.cleared.contains("alex") && notifier.cleared.contains("maria"))
    }
    @Test func openingANotificationSelectsTheConversationAndThread() async throws {
        let (store, _, _) = try await started()
        await store.open(conversation: "design", thread: "d4")
        #expect(store.selectedID == "design" && store.threadID == "d4")
        #expect(store.timeline("design", thread: "d4").map(\.id) == ["r1", "r2"])
    }
    @Test func inlineReplySendsIntoTheThreadWithoutTouchingTheDraft() async throws {
        let (store, notifier, fake) = try await started()
        store.setDraft("half-written", conversation: "design", thread: "d4")
        await store.reply("  on it ", conversation: "design", thread: "d4")
        #expect(await fake.sentDrafts.map(\.text) == ["on it"])
        #expect(store.messages.contains { $0.threadID == "d4" && $0.text == "on it" && $0.delivery == .sent })
        #expect(store.drafts[store.key("design", "d4")] == "half-written")
        #expect(await fake.markedRead.last == "design" && notifier.cleared.contains("design"))
    }
}

/// Someone's call in a DM notifies, as Google Chat's web client does: Google posts a "Call started" message as it rings.
@MainActor struct IncomingCallTests {
    let maria = Person(id: "maria", name: "Maria Chen")
    let dm = Conversation(id: "dm/b", name: "Maria Chen", kind: .direct, members: [])
    let now = Date(timeIntervalSince1970: 1_000_000)
    func call(_ status: Parley.Attachment.CallStatus = .started, huddle: Bool = false, in conversation: Conversation? = nil,
              from sender: Person? = nil, at time: Date? = nil, id: String = "c1") -> Message {
        var chip = Parley.Attachment(name: "Call started", kind: .call, url: URL(string: "https://meet.google.com/abc-defg-hij"), call: status)
        if huddle { chip.huddle = true }
        return Message(id: "\((conversation ?? dm).id)/\(id)/\(id)", conversationID: (conversation ?? dm).id, sender: sender ?? maria, text: "",
                       createdAt: time ?? now, attachments: [chip])
    }
    func incoming(_ message: Message, in conversation: Conversation? = nil) -> Bool {
        NotificationPolicy.isIncomingCall(message, in: conversation ?? dm, me: "me", now: now)
    }

    @Test func aCallStartedInADMIsAnIncomingCall() {
        #expect(incoming(call()))
        #expect(!incoming(call(huddle: true)))                                // a huddle is an ordinary notification
        #expect(!incoming(call(.missed)) && !incoming(call(.ended)) && !incoming(call(.join)))
        #expect(!incoming(call(from: Person(id: "me", name: "Dave"))))       // my own call
        #expect(!incoming(call(at: now.addingTimeInterval(-120))))           // history
        let space = Conversation(id: "space/a", name: "Design", kind: .space, members: [])
        #expect(!incoming(call(in: space), in: space))
    }
    @Test func anIncomingCallNotifiesWithJoinEvenWithItsDMOnScreen() async throws {
        let store = ChatStore(backend: FakeBackend()), notifier = RecordingNotifier()
        store.notifier = notifier
        store.notificationSettings = { NotificationSettings() }
        store.isAppActive = { true }
        await store.start()
        let dm = try #require(store.conversations.first { $0.kind == .direct && !$0.muted && $0.notificationLevel != .off })
        await store.select(dm.id)
        store.apply(.messageUpserted(call(in: dm, at: .now)))
        let note = try #require(notifier.posted.last)
        #expect(note.isCall && note.title == "Maria Chen" && note.body == "Calling you" && note.join == URL(string: "https://meet.google.com/abc-defg-hij"))
        store.apply(.messageUpserted(call(huddle: true, in: dm, at: .now, id: "h1")))   // a huddle on screen: no banner
        #expect(notifier.posted.count == 1)
        var muted = dm; muted.muted = true
        store.apply(.conversationUpserted(muted))
        store.apply(.messageUpserted(call(in: dm, at: .now, id: "c2")))
        #expect(notifier.posted.count == 1)                                 // a muted DM stays quiet
    }
}

/// Notification sounds are the Mac's own, played by macOS, so Focus and Parley's notification settings apply to them as
/// to any app: macOS's default, none, or a sound installed on the Mac (System, Library or the user's Sounds folder).
struct NotificationSoundTests {
    @Test func thePickerOffersDefaultNoneAndTheMacsSounds() throws {
        let one = FileManager.default.temporaryDirectory.appending(path: "Sounds-\(UUID().uuidString)")
        let two = FileManager.default.temporaryDirectory.appending(path: "Sounds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: one); try? FileManager.default.removeItem(at: two) }
        for folder in [one, two] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        for file in ["Glass.aiff", "Basso.aiff", "notes.txt"] { try Data().write(to: one.appending(path: file)) }
        for file in ["Glass.aiff", "Ping.wav"] { try Data().write(to: two.appending(path: file)) }   // the same name once
        let offered = NotificationSound.available(in: [one, two])
        #expect(offered == [.standard, .none, .named("Basso.aiff"), .named("Glass.aiff"), .named("Ping.wav")])
        #expect(offered.map(\.name) == ["Default", "None", "Basso", "Glass", "Ping"])
    }
    @Test func aChoiceIsStoredByNameAndOldParleySoundsBecomeTheDefault() {
        for sound in [NotificationSound.standard, .none, .named("Glass.aiff")] { #expect(NotificationSound(stored: sound.stored) == sound) }
        #expect(NotificationSound(stored: nil) == .standard)
        for old in ["duet", "drop", "rise"] { #expect(NotificationSound(stored: old) == .standard) }   // Parley's own, gone
    }
    /// macOS plays only its default sound for an app (it swaps any other for it), so Default is macOS's, with its Focus
    /// rules, and a named sound is Parley's to play: the banner goes silent.
    @Test func defaultIsMacOSsAndANamedSoundIsParleys() {
        #expect(NotificationSound.standard.notificationSound == .default && !NotificationSound.standard.playedByParley)
        #expect(NotificationSound.none.notificationSound == nil && !NotificationSound.none.playedByParley)
        #expect(NotificationSound.named("Glass.aiff").notificationSound == nil && NotificationSound.named("Glass.aiff").playedByParley)
        #expect(SystemNotifier.presentation(.standard) == [.banner, .list, .sound])
        #expect(SystemNotifier.presentation(.named("Glass.aiff")) == [.banner, .list])
    }
    /// A sound Parley plays: whenever sounds are allowed for Parley, during a Focus too, as Slack plays its own.
    @Test func parleyPlaysANamedSoundWhenSoundsAreAllowed() {
        #expect(NotificationSoundPolicy.plays(.named("Glass.aiff"), soundsAllowed: true))
        #expect(!NotificationSoundPolicy.plays(.named("Glass.aiff"), soundsAllowed: false))
        #expect(!NotificationSoundPolicy.plays(.standard, soundsAllowed: true))   // macOS plays it
        #expect(!NotificationSoundPolicy.plays(.none, soundsAllowed: true))
    }
}
