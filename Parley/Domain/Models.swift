import Foundation
import ImageIO
import UniformTypeIdentifiers

typealias ConversationID = String
typealias MessageID = String
typealias ThreadID = String
/// A thread in its own window.
struct ThreadRef: Codable, Hashable { var conversation: ConversationID; var thread: ThreadID }
typealias PersonID = String

/// The live value is `ChatStore.presence`; `Person.presence` is only the demo's and launch caches' copy.
enum Presence: String, Codable, Sendable { case available, away, offline, doNotDisturb }
struct Person: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var name: String
    var presence: Presence = .offline
    var avatarURL: URL? = nil   // public FIFE photo
    var email: String? = nil
}
extension Person {
    /// Someone known only by an email address: `ChatBackend.directMessage` invites them by email.
    static func invite(email: String) -> Person { Person(id: "email:" + email, name: email, email: email) }
    static func invitedEmail(_ id: PersonID) -> String? { id.hasPrefix("email:") ? String(id.dropFirst(6)) : nil }
}
/// A space from the directory, joined or not.
struct SpaceListing: Identifiable, Hashable, Sendable {
    let id: ConversationID
    var name: String
    var emoji: String? = nil
    var avatarURL: URL? = nil
    var memberCount: Int? = nil
    var joined = false
}
enum ConversationKind: String, Codable, Sendable { case direct, group, space }
struct Conversation: Identifiable, Hashable, Codable, Sendable {
    let id: ConversationID
    var name: String
    var kind: ConversationKind
    var members: [Person]
    var unread: Int = 0
    var pinned = false
    var muted = false
    var emoji: String? = nil    // a space's emoji icon; shown before avatarURL
    var avatarURL: URL? = nil   // space image, or the other person's photo in a 1:1 DM
    var description: String? = nil   // a space's description
    var notificationLevel: NotificationLevel? = nil   // as Google Chat stores it for me; nil until the server reports it
    var app: App? = nil   // a 1:1 DM (`.direct`) with an app instead of a person
    enum App: String, Codable, Sendable { case bot, gemini }   // gemini: Ask Gemini, a sidebar shortcut in Google Chat
    var activity: Date? = nil   // the server's last-activity time (its sidebar sort time), which Home orders by
}
struct Reaction: Hashable, Codable, Sendable {
    var emoji: String   // a custom emoji's is ":shortcode:"
    var people: Set<String>
    var custom: CustomEmoji? = nil
}
/// A Workspace organisation's own emoji. In `Message.text` it is one U+FFFD that a `.customEmoji` range covers.
struct CustomEmoji: Hashable, Codable, Sendable {
    var id: String
    var shortcode: String         // without colons
    var imageURL: URL? = nil      // fetched with `ChatBackend.attachmentData` (see `image`)
    var deleted = false           // shown as ":shortcode:"
    var payload = Data()          // the backend's own copy, sent back unchanged when reacting
    var text: String { ":\(shortcode):" }
    /// The image as an attachment, so it loads through `ChatBackend.attachmentData` and `ImageCache` like other pictures.
    var image: Attachment? {
        imageURL.map { Attachment(name: text, contentType: "image/png", kind: .image, thumbnailURL: $0, url: $0, width: 64, height: 64) }
    }
}
enum Delivery: String, Codable, Sendable { case pending, sent, failed }
/// An uploaded file or image, a Drive file, or a link preview. Bytes come from `ChatBackend.attachmentData`.
struct Attachment: Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case image, video, file, link, voice, call, card }   // link: opens in the browser; voice: a recorded voice message; call: a Google Meet call; card: an app's card
    var name: String
    var contentType = ""
    var kind: Kind
    var thumbnailURL: URL? = nil
    var url: URL? = nil      // full size / download / page
    var width: Int? = nil    // known pixel size, so the timeline can reserve space
    var height: Int? = nil
    var snippet: String? = nil  // link preview description
    var domain: String? = nil   // set only on link previews, which render as a card
    var uploadToken: String? = nil   // opaque, from `ChatBackend.upload`: set on a local file once it is uploaded
    var voice: Voice? = nil          // set on `.voice`
    var call: CallStatus? = nil      // set on `.call`
    var huddle: Bool? = nil          // true on a huddle's `.call`, which never rings
    var cacheKey: String? = nil      // "<message id>#<place>": its picture's cache key, as its URL changes on every load
    var card: Card? = nil            // set on `.card`
    enum CallStatus: String, Codable, Sendable { case started, missed, ended, join }   // join: a Meet link
    /// Links and calls open in the browser; the rest preview with Quick Look.
    var opensInBrowser: Bool { kind == .link || kind == .call }
}
/// An app's card, read-only, as Google Chat draws it under the message: sections of items.
struct Card: Hashable, Codable, Sendable {
    var sections: [[Item]]
    enum Item: Hashable, Codable, Sendable {
        case text(String, [TextStyleRange], lines: Int? = nil)   // lines: cut to that many; nil: all
        /// A row with an optional icon (round: an avatar), a small label above, and its text.
        case row(icon: URL?, round: Bool, label: String?, text: String, formatting: [TextStyleRange], open: URL? = nil)   // open: a click on the row opens it
        case links([Link])
        case image(URL, aspect: Double)   // width over height
        case divider
        case input(name: String, label: String, value: String)   // a text field; its value goes with the card's actions
    }
    /// What a card sends back with an action: its text fields, by name.
    struct Input: Hashable, Codable, Sendable { var name: String; var value: String }
    /// The card's text fields as they arrived (`CardView` keeps what is typed).
    var inputs: [Input] {
        sections.flatMap { $0 }.compactMap { if case .input(let name, _, let value) = $0 { Input(name: name, value: value) } else { nil } }
    }
    struct Link: Hashable, Codable, Sendable {
        var title: String; var url: URL
        var trailing: Bool? = nil   // set at the row's end (a button in an end-aligned column)
        var filled: Bool? = nil     // a filled button; otherwise outlined, as Google Chat draws a card's buttons
        var action: Data? = nil     // an action Parley sends (`ChatBackend.clickCard`); `url` is then the fallback
    }
    /// The app that made the card, shown under it as Google Chat does: "By <app>" and an App badge; nil: none.
    var by: Attribution? = nil
    struct Attribution: Hashable, Codable, Sendable { var name: String; var icon: URL? }
    /// A button that hides the card in Parley only (an app suggestion's "Don't install"); nil: none.
    var dismiss: String? = nil
    /// Grey for a card's small print, such as "Only visible to you": readable on light and dark.
    static let secondaryText: UInt32 = 0xFF80868B
}
/// What a voice message carries besides its audio, as Google Chat sends it.
/// A message as Google translated it for me (into my language), and the language it was written in.
struct Translation: Hashable, Codable, Sendable {
    var text: String
    var formatting: [TextStyleRange] = []
    var from: String   // a language tag ("es")
}
struct Voice: Hashable, Codable, Sendable {
    var duration: TimeInterval
    var waveform: [Int] = []          // one 0…100 level per 100 ms; empty: computed from the audio once it loads
    var transcript: String? = nil     // the server's, once it has transcribed the message
    /// Google Chat names a recording after the time it was made.
    static func fileName(at date: Date = .now) -> String { "UserRecording_\(Int64((date.timeIntervalSince1970 * 1000).rounded())).m4a" }
    /// Google Chat labels its AAC recordings this way.
    static let contentType = "audio/mpeg"
}
/// A style over part of `Message.text`, in UTF-16 units (`NSRange` offsets).
struct TextStyleRange: Hashable, Codable, Sendable {
    enum Style: Hashable, Codable, Sendable {
        case bold, italic, strike, underline, code, codeBlock, listItem, heading, quote
        case small   // a card's small print (a bottom label): smaller type
        case nowrap  // its paragraph stays on one line, cut with "…" (a card row that doesn't wrap)
        case mention(userID: String?)   // the mentioned user; nil in launch caches written before it was kept
        case link(URL)
        case customEmoji(CustomEmoji)   // over the one U+FFFD that stands for it
        case color(UInt32)              // text colour, ARGB, as Google Chat stores it
        // A space or DM chip over its name: the space's emoji when known, and the link it was made from (a message's, maybe).
        case chip(ConversationID, emoji: String? = nil, link: URL? = nil)
    }
    var style: Style
    var start: Int
    var length: Int
    /// The user id an @all mention carries.
    static let everyone = "@all"
    /// `text` with each custom emoji written as ":shortcode:", for places that show plain text (quotes, notifications).
    /// `plain`, with where each custom emoji's ":shortcode:" ended up, for text that draws them as pictures.
    static func plainWithEmoji(_ text: String, _ formatting: [TextStyleRange]) -> (text: String, emoji: [TextStyleRange]) {
        let plain = NSMutableString(string: text)
        var emoji: [TextStyleRange] = [], shift = 0
        for range in formatting.sorted(by: { $0.start < $1.start }) where range.start >= 0 && range.start + range.length <= (text as NSString).length {
            guard case .customEmoji(let custom) = range.style else { continue }
            let at = NSRange(location: range.start + shift, length: range.length), code = custom.text as NSString
            plain.replaceCharacters(in: at, with: code as String)
            emoji.append(TextStyleRange(style: range.style, start: at.location, length: code.length))
            shift += code.length - range.length
        }
        return (plain as String, emoji)
    }
    static func plain(_ text: String, _ formatting: [TextStyleRange]) -> String {
        let plain = NSMutableString(string: text)
        for range in formatting.sorted(by: { $0.start > $1.start }) where range.start >= 0 && range.start + range.length <= plain.length {
            if case .customEmoji(let emoji) = range.style { plain.replaceCharacters(in: NSRange(location: range.start, length: range.length), with: emoji.text) }
        }
        return plain as String
    }
}
/// The text colours Google Chat's composer offers, with the ARGB values it sends; light and dark alike.
enum TextColor: CaseIterable, Sendable {
    case red, blue, green, amber, grey
    var argb: UInt32 {
        switch self { case .red: 0xFFF4_4336; case .blue: 0xFF21_96F3; case .green: 0xFF4C_AF50; case .amber: 0xFFFF_C107; case .grey: 0xFF9E_9E9E }
    }
    var name: String { "\(self)".capitalized }
}
/// The message a quote reply quotes: as the server snapshotted it, or, on a reply being sent, the message it names.
struct QuotedMessage: Hashable, Codable, Sendable {
    var sender: String
    var text: String
    var id: MessageID? = nil              // set only on a quote being sent
    var lastUpdateMicros: Int64? = nil    // the quoted message's `Message.lastUpdateMicros`, sent with `id`
    var forwardedFrom: String? = nil      // a forward, not a quote reply: the name of the conversation it came from
    var media: Attachment? = nil          // on a quote being sent: its first photo or video, for the composer's thumbnail
    var emoji: [TextStyleRange]? = nil    // its custom emoji, over their ":shortcode:" in `text`, drawn as pictures
    /// What a quote shows: the text, or for a message with none, what it carried, as web Chat names it.
    static func summary(text: String, attachments: [Attachment]) -> String {
        guard text.isEmpty, let first = attachments.first else { return text }
        switch first.kind {
        case .image: return first.contentType == "image/gif" ? "GIF" : "Photo"
        case .video: return "Video"
        case .voice: return "Voice message"
        case .file, .link, .call, .card: return first.name
        }
    }
}
struct Message: Identifiable, Hashable, Codable, Sendable {
    let id: MessageID
    let conversationID: ConversationID
    var threadID: ThreadID? = nil
    var sender: Person
    var text: String
    var createdAt: Date = .now
    var edited = false
    var reactions: [Reaction] = []
    var delivery: Delivery = .sent
    var replyCount = 0
    var attachments: [Attachment] = []
    var formatting: [TextStyleRange] = []
    var quote: QuotedMessage? = nil
    var isSystem = false   // "Ana added Ben": a centered service line, not a bubble; `text` is the line
    var lastUpdateMicros: Int64? = nil   // the server's last update time, which a quote reply sends back
    var via: String? = nil   // the app that posted it on the sender's behalf (e.g. imported history), shown after the name
    var following = false    // on a thread head: I follow the thread, as the server last said
    var starred = false      // I starred it (Google Chat's per-user STAR label)
    var sources: [Source] = []   // a Gemini answer's sources, listed under its text
    var thinking: [ThinkingStep] = []   // the steps behind a Gemini answer ("Show thinking")
    var translation: Translation? = nil   // Google's translation for me; the timeline shows it first, `text` stays the original
}
/// One step of a Gemini answer's reasoning, as Google Chat lists them under "Show thinking".
struct ThinkingStep: Hashable, Codable, Sendable {
    var title: String
    var text: String
}
/// Something a Gemini answer drew on: an email, an event, a document… opened on the web.
struct Source: Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case gmail, calendar, docs, sheets, slides, drive, youtube, chat, tasks, web }
    var title: String
    var url: URL
    var kind: Kind
}
extension Message {
    /// Launch caches written before attachments or formatting existed lack those keys.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(MessageID.self, forKey: .id), conversationID: try c.decode(ConversationID.self, forKey: .conversationID),
                  threadID: try c.decodeIfPresent(ThreadID.self, forKey: .threadID), sender: try c.decode(Person.self, forKey: .sender),
                  text: try c.decode(String.self, forKey: .text), createdAt: try c.decode(Date.self, forKey: .createdAt),
                  edited: try c.decode(Bool.self, forKey: .edited), reactions: try c.decode([Reaction].self, forKey: .reactions),
                  delivery: try c.decode(Delivery.self, forKey: .delivery), replyCount: try c.decode(Int.self, forKey: .replyCount),
                  attachments: try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? [],
                  formatting: try c.decodeIfPresent([TextStyleRange].self, forKey: .formatting) ?? [],
                  quote: try c.decodeIfPresent(QuotedMessage.self, forKey: .quote),
                  isSystem: try c.decodeIfPresent(Bool.self, forKey: .isSystem) ?? false,
                  lastUpdateMicros: try c.decodeIfPresent(Int64.self, forKey: .lastUpdateMicros),
                  via: try c.decodeIfPresent(String.self, forKey: .via),
                  following: try c.decodeIfPresent(Bool.self, forKey: .following) ?? false,
                  starred: try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false,
                  sources: try c.decodeIfPresent([Source].self, forKey: .sources) ?? [],
                  thinking: try c.decodeIfPresent([ThinkingStep].self, forKey: .thinking) ?? [],
                  translation: try c.decodeIfPresent(Translation.self, forKey: .translation))
    }
}
struct MessageDraft: Sendable {
    var text: String; var localID: String; var formatting: [TextStyleRange] = []
    var uploads: [Attachment] = []   // files already uploaded with `ChatBackend.upload` (each has an `uploadToken`)
    var quoting: QuotedMessage? = nil   // a quote reply: the quoted message, with its `id` and `lastUpdateMicros`
    var serverDraftID: String? = nil    // the server draft this message was, which the server drops on send
}
/// A composer's draft as Google Chat keeps it on the server, so it follows the user between devices.
struct ServerDraft: Hashable, Codable, Sendable {
    var id = ""                       // empty until first saved; the backend names it then
    var conversationID: ConversationID
    var threadID: ThreadID? = nil     // a thread's reply box has a draft of its own
    var text: String
    var formatting: [TextStyleRange] = []
    var updatedAt: Date = .now        // the server's last update time
}
struct MessagePage: Sendable { var messages: [Message]; var hasMore: Bool }
/// A conversation's shared content, as the info panel's tabs group it.
enum SharedCategory: String, CaseIterable, Sendable { case media = "Media", files = "Files", links = "Links" }
struct SharedPage: Sendable { var items: [SharedContent.Item]; var hasMore: Bool }
struct SearchPage: Sendable { var messages: [Message]; var cursor: String? = nil }
/// A sidebar shortcut shown in place of a conversation, in the sidebar's order. Home lists conversations by recent
/// activity; Mentions and Starred list messages from every conversation; Drafts lists the unsent drafts.
enum Shortcut: String, CaseIterable, Sendable {
    case home, mentions, starred, drafts
    var title: String { switch self { case .home: "Home"; case .mentions: "Mentions"; case .starred: "Starred"; case .drafts: "Drafts" } }
    var icon: String { switch self { case .home: "house"; case .mentions: "at"; case .starred: "star"; case .drafts: "doc" } }
}
/// A thread Home lists on a row of its own, beside its conversation's row: its first message and its newest reply.
struct HomeThread: Identifiable, Hashable, Codable, Sendable {
    let id: ThreadID                  // the first message's id, as `Message.threadID` names it
    var conversationID: ConversationID
    var head: Message
    var latest: Message               // the newest reply
    var unread: Bool                  // a reply from someone else I haven't read
    var time: Date                    // the server's sort time (its newest reply), which Home orders by
}
/// One Home row: a conversation with its newest message, or (`thread` set) a thread with its newest reply.
struct HomeRow: Identifiable, Hashable {
    var room: Conversation
    var last: Message?
    var thread: HomeThread? = nil
    var time: Date
    var id: String { thread?.id ?? room.id }
    var unread: Bool { thread?.unread ?? (room.unread > 0) }
}
enum ConnectionState: String, Codable, Sendable {
    case offline = "Offline", connecting = "Connecting…", connected = "Connected", reconnecting = "Reconnecting…", signedOut = "Signed out"
}
enum ChatEvent: Sendable, Equatable {
    case messageUpserted(Message), messageDeleted(MessageID)
    case conversationUpserted(Conversation), conversationRemoved(ConversationID)   // removed: left, removed from, or deleted
    case readStateChanged(ConversationID, unread: Int)
    /// I started or stopped following a thread (here or elsewhere).
    case threadFollowChanged(ThreadID, following: Bool)
    /// Someone reacted to a message, or took it back, as pushed live (never replayed). `emoji` is a custom one's ":shortcode:".
    case reacted(MessageID, emoji: String, by: PersonID, added: Bool)
    /// Someone else started or stopped typing; `thread` set when they type in that thread's reply box.
    case typingChanged(ConversationID, ThreadID?, String, isTyping: Bool)
    /// An agent (Ask Gemini) working in a thread, with its status ("Collecting info"); nil once it stopped.
    case activityChanged(ConversationID, ThreadID?, String, label: String?)
    /// Readers' newest read times (never mine), merged per person; `enabled: false` turns receipts off and clears them.
    case readReceiptsChanged(ConversationID, [String: Date], enabled: Bool?)
    /// nil presence: unchanged (a status push carries no active/away bit); `status` is the custom status, nil when none.
    case presenceChanged(String, Presence?, status: String?)
    /// A server draft created or changed (here or on another device), or deleted (by its id).
    case draftChanged(ServerDraft), draftDeleted(String)
    case connectionChanged(ConnectionState)
    case resync
}
protocol ChatBackend: Sendable {
    var events: AsyncStream<ChatEvent> { get }
    /// Verifies the session and returns the signed-in person.
    func connect() async throws -> Person
    func conversations() async throws -> [Conversation]
    func messages(in conversation: ConversationID, thread: ThreadID?, before: Date?) async throws -> MessagePage
    func send(_ draft: MessageDraft, to conversation: ConversationID, thread: ThreadID?) async throws -> Message
    /// Makes a Google Meet meeting for the conversation and posts it, as Google Chat's "Send a Meet link" does.
    func sendMeetLink(in conversation: ConversationID) async throws -> Message
    func edit(_ id: MessageID, text: String, formatting: [TextStyleRange]) async throws
    func delete(_ id: MessageID) async throws
    /// `custom`: the reaction's custom emoji, which goes back to the server as it came.
    func setReaction(_ emoji: String, custom: CustomEmoji?, on id: MessageID, present: Bool) async throws
    /// Everyone who reacted to a message with `emoji`, as the server lists them (up to 100).
    func reactors(of id: MessageID, emoji: String, custom: CustomEmoji?) async throws -> [Person]
    func markRead(_ conversation: ConversationID) async throws
    /// Marks the newest message unread until the conversation is read again.
    func markUnread(_ conversation: ConversationID) async throws
    /// Pins (stars) a conversation in my sidebar, or unpins it.
    func setPinned(_ pinned: Bool, conversation: ConversationID) async throws
    /// Mutes a conversation's notifications, or unmutes them; the notification level stays as it was.
    func setMuted(_ muted: Bool, conversation: ConversationID) async throws
    /// Sets when a conversation notifies me; `muted` is resent as it is, since the server stores both together.
    func setNotificationLevel(_ level: NotificationLevel, muted: Bool, conversation: ConversationID) async throws
    /// Leaves a space or group conversation.
    func leave(_ conversation: ConversationID) async throws
    func searchMessages(_ query: String, cursor: String?) async throws -> SearchPage
    /// Thumbnail (or the full file when there is none) for display; `thumbnail: false` for the original.
    func attachmentData(_ attachment: Attachment, thumbnail: Bool) async throws -> Data
    /// Uploads a local file (`Attachment.localFile`) for a message in `conversation`; returns it with `uploadToken` set.
    func upload(_ attachment: Attachment, to conversation: ConversationID, thread: ThreadID?) async throws -> Attachment
    /// Everyone who has joined `conversation`, for @-mentions.
    func members(of conversation: ConversationID) async throws -> [Person]
    /// "I'm typing" (there is no "stopped": receivers time it out). Throttling is the caller's.
    func sendTyping(conversation: ConversationID, thread: ThreadID?) async throws
    /// The conversations open on screen, as a full replacement set: typing is only pushed for these.
    func watch(_ conversations: Set<ConversationID>) async
    /// One batched lookup; answers arrive as `.presenceChanged` events.
    func fetchPresence(_ people: [String]) async throws
    /// People to start a conversation with, matching `query` by name or email; never me.
    func searchPeople(_ query: String) async throws -> [Person]
    /// The DM with these people (one: 1:1, several: a group DM), found or else created.
    func directMessage(with people: [PersonID]) async throws -> Conversation
    /// Spaces in the directory matching `query`.
    func browseSpaces(_ query: String) async throws -> [SpaceListing]
    /// Joins a space and returns it as a conversation.
    func join(_ space: SpaceListing) async throws -> Conversation
    /// The media, files or links shared in a conversation, newest first, without its history;
    /// `after` is the last item of the previous page.
    func shared(_ category: SharedCategory, in conversation: ConversationID, after: SharedContent.Item?) async throws -> SharedPage
    /// The organisation's custom emoji that can be sent (enabled ones), every page.
    func customEmojis() async throws -> [CustomEmoji]
    /// Stars a message for me, or unstars it.
    func setStarred(_ starred: Bool, on id: MessageID) async throws
    /// Sends a card button's action and the card's inputs back to its app; returns the message as the app updated it.
    func clickCard(_ id: MessageID, action: Data, inputs: [Card.Input]) async throws -> Message?
    /// One page of a shortcut's messages, newest first; `cursor` is the previous page's.
    func shortcut(_ shortcut: Shortcut, cursor: String?) async throws -> SearchPage
    /// The threads Home lists, newest first, as the last `conversations()` brought them.
    func homeThreads() async -> [HomeThread]
    /// Every server draft.
    func drafts() async throws -> [ServerDraft]
    /// Creates the draft when its `id` is empty, else replaces its text and formatting; returns it as saved (id, update time).
    func saveDraft(_ draft: ServerDraft) async throws -> ServerDraft
    func deleteDraft(_ draft: ServerDraft) async throws
}


enum AttachmentError: Error, LocalizedError, Equatable {
    case notAFile(String), empty(String), tooLarge(String)
    var errorDescription: String? {
        switch self {
        case .notAFile(let name): "“\(name)” isn’t a file that can be attached."
        case .empty(let name): "“\(name)” is empty."
        case .tooLarge(let name): "“\(name)” is larger than Google Chat’s 200 MB limit."
        }
    }
}
extension Attachment {
    /// Google Chat refuses larger uploads.
    static let maxUploadBytes = 200_000_000
    /// Not sent yet: a file on this Mac, shown from disk until the server's copy replaces it.
    var isLocalFile: Bool { url?.isFileURL == true }
    /// A file picked, pasted or dropped into the composer. Images keep their pixel size so the echo reserves its space.
    static func localFile(at url: URL) throws -> Attachment {
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
        guard url.isFileURL, values?.isRegularFile == true, let size = values?.fileSize else { throw AttachmentError.notAFile(name) }
        guard size > 0 else { throw AttachmentError.empty(name) }
        guard size <= maxUploadBytes else { throw AttachmentError.tooLarge(name) }
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        var file = Attachment(name: name, contentType: type.preferredMIMEType ?? "application/octet-stream",
                              kind: type.conforms(to: .image) ? .image : .file, url: url)
        if file.kind == .image, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            file.width = properties[kCGImagePropertyPixelWidth] as? Int
            file.height = properties[kCGImagePropertyPixelHeight] as? Int
            file.thumbnailURL = url
        }
        return file
    }
}

extension Message {
    /// How many emoji the message is when it is only one to three of them (custom ones too) and nothing else: drawn
    /// large and without a bubble, as Telegram and WhatsApp show them. Nil for any other message.
    var jumboEmoji: Int? {
        guard attachments.isEmpty, quote == nil,
              formatting.allSatisfy({ if case .customEmoji = $0.style { $0.length == 1 } else { false } }) else { return nil }
        let custom = Set(formatting.map(\.start))
        var count = 0, offset = 0   // UTF-16 offsets, as the formatting ranges count
        for character in text {
            defer { offset += character.utf16.count }
            if character.isWhitespace { continue }
            let emoji = character == "\u{FFFD}" ? custom.contains(offset) : character.isEmojiGlyph
            guard emoji else { return nil }
            count += 1
        }
        return (1...3).contains(count) ? count : nil
    }
}

extension Character {
    /// Drawn as an emoji: an emoji-style character, or one made emoji by a variation selector, skin tone or joiner.
    /// Digits, "#" and "©", which are emoji only with a selector, are not.
    var isEmojiGlyph: Bool {
        guard let first = unicodeScalars.first?.properties else { return false }
        return first.isEmojiPresentation || (first.isEmoji && unicodeScalars.count > 1)
    }
}
