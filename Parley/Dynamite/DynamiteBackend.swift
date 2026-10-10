import AppKit
import Foundation
import Network
import os
import SwiftProtobuf

/// `ChatBackend` over Dynamite RPCs, with realtime events from Google Chat's Punctual channel.
actor DynamiteBackend: ChatBackend {
    nonisolated let events: AsyncStream<ChatEvent>
    private let continuation: AsyncStream<ChatEvent>.Continuation
    private let authorizer: WebSessionAuthorizer
    private let client: DynamiteClient
    private let realtime: Bool
    private let log = Logger(subsystem: "dev.cuza.Parley", category: "dynamite")
    private var selfID = ""
    private var people: [String: Person] = [:]
    private var unresolvable: Set<String> = []
    private var refreshedSenders: Set<String> = []   // re-read once per session (see refreshSender)   // "<bots>/<id>" the server omitted (deleted, external): not asked again
    // ponytail: replies come from the last list_topics page (≤20 per topic) plus pushes. Full threads need list_messages (schema not yet decoded).
    private var threads: [MessageID: [Message]] = [:]
    private var heads: [String: Message] = [:]   // "<conversation>/<topic>" → thread head
    private var oldestSort: [ConversationID: Int64] = [:]
    private var reachedStart: Set<ConversationID> = []
    private var threadStart: Set<ThreadID> = []
    private var channel: Task<Void, Never>?
    private var realtimeChannel: PunctualChannel?
    private var watched: Set<ConversationID> = []
    private var pathMonitor: NWPathMonitor?
    private var wakeObserver: (any NSObjectProtocol)?
    private var userRevision: Int64 = 0
    // While the realtime channel is down, events are polled with catch_up_user, as a reconnect replays them.
    private var poller: Task<Void, Never>?
    private var channelState: ConnectionState = .connecting
    private var lastPoll: ContinuousClock.Instant?
    static let pollInterval: Duration = .seconds(10)
    private var newest: [ConversationID: Int64] = [:]   // newest server create time seen (µs), for mark-read
    private var readUpTo: [ConversationID: Int64] = [:]
    private var readyBefore = false
    // From the sidebar read, for the sidebar actions.
    private var latest: [ConversationID: Int64] = [:]   // newest message time (µs) the sidebar reported
    private var notifyLevel: [ConversationID: Dynamite_GroupNotificationSettings.Level] = [:]
    private var markedUnread: Set<ConversationID> = []
    // A loaded message's attachments and chips (annotations not rebuilt from its text), re-sent on edit so they survive it.
    // ponytail: kept for every loaded message with attachments, like `threads`; prune with them if memory ever matters.
    private var attached: [MessageID: (text: String, annotations: [Dynamite_Annotation])] = [:]

    private let vault: any SessionVault
    private let media: URLSession

    /// `vault` must be the authorizer's: media reuses its stored cookies (see `attachmentData`).
    init(authorizer: WebSessionAuthorizer, realtime: Bool = true, vault: any SessionVault = KeychainSessionVault(), media: URLSession? = nil) {
        self.authorizer = authorizer
        self.realtime = realtime
        self.vault = vault
        self.media = media ?? URLSession(configuration: Self.mediaConfiguration(), delegate: NoAuthRedirects(), delegateQueue: nil)
        client = DynamiteClient(authorizer: authorizer)
        let stream = AsyncStream<ChatEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }

    func connect() async throws -> Person {
        let status: Dynamite_GetSelfUserStatusResponse = try await rpc(
            "get_self_user_status", Dynamite_GetSelfUserStatusRequest.with { $0.requestHeader = DynamiteClient.header })
        guard !status.userStatus.userID.id.isEmpty else { throw AuthFailure.malformedProto }
        selfID = status.userStatus.userID.id
        readyBefore = false   // a fresh load follows every connect
        await resolve([selfID])
        continuation.yield(.connectionChanged(.connecting))
        if realtime {
            channel?.cancel()
            let punctual = PunctualChannel(authorizer: authorizer,
                                           onEvent: { [weak self] in await self?.apply($0) },
                                           onState: { [weak self] in await self?.channelChanged($0) })
            await punctual.subscribe(watched)
            self.realtimeChannel = punctual
            channel = Task { await punctual.run() }
            // Polling starts from now: what came before is in the pages this connect loads.
            userRevision = max(userRevision, Int64(Date.now.timeIntervalSince1970 * 1_000_000))
            poller?.cancel()
            poller = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.pollInterval)
                    guard let self, !Task.isCancelled else { return }
                    if await self.channelState != .connected { await self.poll() }
                }
            }
            // Network back or Mac awake: reconnect now instead of waiting out the backoff.
            stopNudges()
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in if path.status == .satisfied { Task { await punctual.nudge() } } }
            monitor.start(queue: .global(qos: .utility))
            pathMonitor = monitor
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
                Task { await punctual.nudge() }
            }
        }
        return people[selfID] ?? Person(id: selfID, name: "Me")
    }
    /// Closes the realtime channel and polling; tests end an event stream with it.
    func disconnect() {
        channel?.cancel()
        channel = nil
        poller?.cancel()
        poller = nil
        realtimeChannel = nil
        stopNudges()
        continuation.yield(.connectionChanged(.offline))
    }
    private func stopNudges() {
        pathMonitor?.cancel()
        pathMonitor = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    func conversations() async throws -> [Conversation] {
        let (sorted, topics) = try await worldItems()
        sorted.forEach(remember)
        await resolve(sorted.flatMap(DynamiteMapper.memberIDs))
        await resolve(messages: topics.flatMap(\.replies))
        home = topics.compactMap { DynamiteMapper.homeThread($0, selfID: selfID, people: people) }.sorted { $0.time > $1.time }
        return sorted.compactMap { DynamiteMapper.conversation($0, selfID: selfID, people: people) }
    }
    private var home: [HomeThread] = []
    func homeThreads() -> [HomeThread] { home }
    /// Home's sections, as Google Chat's web client sends them; the topics they bring arrive in the response's field 7.
    /// The section replies only echo their filters (no items, no token). Checked live: the followed threads come back
    /// only when the last section (label "100G", sort 4) is sent with the first or third; neither brings them alone.
    static let homeSections: [Dynamite_WorldSectionRequest] = {
        let unmuted = Dynamite_WorldFilter.with { $0.muteState = 1; $0.excludeLabels = [.with { $0.type = 3 }] }   // UNMUTED, not MUTED
        let unread = Dynamite_WorldFilter.with {
            $0.readState = 4; $0.muteState = 1; $0.includeLabels = [.with { $0.type = 5 }]; $0.excludeLabels = [.with { $0.type = 3 }]   // + HAS_UNREAD_MAIN_MESSAGE
        }
        let flagged = Dynamite_WorldFilter.with { $0.flag17 = true }
        let threads = Dynamite_WorldTopicFilter.with { $0.labels = [.with { $0.type = 1 }]; $0.field4 = true }
        let unreadThreads = Dynamite_WorldTopicFilter.with { $0.field1 = 1; $0.labels = [.with { $0.type = 1 }, .with { $0.type = 2 }]; $0.field4 = true }
        return [(unmuted, threads), (unread, unreadThreads), (flagged, threads), (flagged, unreadThreads)].map { filter, topics in
            .with { s in
                s.pageSize = 30
                s.worldFilter = filter
                s.topicFilter = topics
                s.topicOption = .with { $0.page = .with { $0.field1 = 1; $0.field2 = true }; $0.flag.field1 = true }
                s.sortKey.sort = 1     // SORT_BY_SORT_TIME_DESC
                s.view.view = 1        // HOME
            }
        } + [.with { s in
            s.pageSize = 30
            s.topicOption = .with { $0.page = .with { $0.field1 = 1; $0.field2 = true }; $0.flag.field1 = true }
            s.sortKey.sort = 4
            s.constraints.constraints = [.with { c in
                c.kind = 3
                c.expression.binary = .with { $0.op = 2; $0.left.text = "label"; $0.right.text = "100G" }
            }]
        }]
    }()
    private func remember(_ item: Dynamite_WorldItemLite) {
        guard let id = DynamiteID.conversation(item.groupID) else { return }
        let state = item.readState
        latest[id] = state.lastHeadMessageCreateTime > 0 ? state.lastHeadMessageCreateTime : item.sortTimestamp
        notifyLevel[id] = state.notificationSettings.level
        if state.markAsUnreadTimestamp > 0 { markedUnread.insert(id) } else { markedUnread.remove(id) }
    }
    /// Every sidebar item, one per conversation, most recent first, and the topics Home's sections brought.
    private func worldItems() async throws -> ([Dynamite_WorldItemLite], [Dynamite_Topic]) {
        // Joined conversations (unfiltered), plus DMs someone started with us that we haven't accepted yet:
        // The mobile app asks for those in their own section, the web lists them in the sidebar.
        let invited = Dynamite_WorldFilter.with { $0.membershipState = .memberInvited; $0.inviteCategory = .regularInvite; $0.groupType = .dm }
        var sections: [Dynamite_WorldSectionRequest] = [.with { $0.pageSize = 200 }, .with { $0.pageSize = 120; $0.worldFilter = invited }] + Self.homeSections
        var items: [Dynamite_WorldItemLite] = [], topics: [Dynamite_Topic] = []
        var seen: Set<String> = []
        for page in 0... {
            guard page < 100 else { throw AuthFailure.malformedProto }
            let request = Dynamite_PaginatedWorldRequest.with { r in
                r.requestHeader = DynamiteClient.header
                r.worldSectionRequests = sections
                r.fetchFromUserSpaces = true
                r.fetchSnippetsForUnnamedRooms = true
            }
            let response: Dynamite_PaginatedWorldResponse = try await rpc("paginated_world", request)
            items += response.worldItems + response.worldSectionResponses.flatMap(\.worldItems)
            if page == 0 { topics = response.shortcutItems.compactMap { if case .topic(let topic)? = $0.item { topic } else { nil } } }
            // A section's response echoes its filter; that is how its next token finds it. An unmatched token is dropped.
            let more = response.worldSectionResponses.filter { $0.moreItems && !$0.paginationToken.isEmpty }
            // Home's sections never page (no token), and the followed-threads one shares the unfiltered section's empty filter.
            sections = sections.filter { !$0.hasView && !$0.hasConstraints }.compactMap { section in
                more.first { $0.worldFilter == section.worldFilter }.map { next in
                    var section = section; section.paginationToken = next.paginationToken; return section
                }
            }
            if sections.isEmpty { break }
            guard sections.allSatisfy({ seen.insert($0.paginationToken).inserted }) else { throw AuthFailure.malformedProto }
        }
        var unique: [ConversationID: Dynamite_WorldItemLite] = [:]
        for item in items { if let id = DynamiteID.conversation(item.groupID), unique[id] == nil { unique[id] = item } }
        return (unique.values.sorted { $0.sortTimestamp > $1.sortTimestamp }, topics)
    }

    func messages(in conversation: ConversationID, thread: ThreadID?, before: Date?) async throws -> MessagePage {
        if let thread { return try await threadPage(thread, in: conversation, older: before != nil) }
        let older = before != nil
        if older, reachedStart.contains(conversation) || oldestSort[conversation] == nil { return MessagePage(messages: [], hasMore: false) }
        let request = try Dynamite_ListTopicsRequest.with { r in
            r.requestHeader = DynamiteClient.header
            r.groupID = try DynamiteID.group(conversation)
            r.field11 = 2   // as Google Chat sends it (see the proto)
            r.pageSizeForTopics = 30
            // Google Chat always asks for TOPIC_METADATA: it carries each thread's real reply count. READ_RECEIPTS fills field 6.
            r.fetchOptions = older ? [.topicMetadata] : [.topicMetadata, .readReceipts]
            r.pageSizeForUnreadReplies = 20
            r.pageSizeForReadReplies = 20
            if older, let anchor = oldestSort[conversation] { r.filter.olderThan = anchor }   // PAGINATION_BACKWARDS
        }
        let response: Dynamite_ListTopicsResponse = try await rpc("list_topics", request)
        if response.hasReadReceiptSet { receipts(response.readReceiptSet, in: conversation) }
        saw(response.topics.flatMap(\.replies), in: conversation)
        await resolve(messages: response.topics.flatMap(\.replies))
        let oldest = response.topics.map(\.sortTime).filter { $0 > 0 }.min()
        if older, let anchor = oldestSort[conversation] {
            // Nothing older than the anchor: we're at the start, or the server ignored the anchor. Either way, stop.
            if let oldest, oldest < anchor { oldestSort[conversation] = oldest } else { reachedStart.insert(conversation) }
        } else {
            oldestSort[conversation] = oldest   // a fresh most-recent load restarts paging from its own oldest thread
        }
        if response.containsFirstTopic { reachedStart.insert(conversation) } else if !older { reachedStart.remove(conversation) }
        let topics = response.topics.map { DynamiteMapper.topic($0, in: conversation, selfID: selfID, people: people) }.filter { !$0.isEmpty }
        for topic in topics {
            threads[topic[0].id] = Array(topic.dropFirst())
            heads[Self.topicKey(topic[0].id)] = topic[0]
        }
        return MessagePage(messages: topics.map { $0[0] }, hasMore: !reachedStart.contains(conversation))
    }

    func send(_ draft: MessageDraft, to conversation: ConversationID, thread: ThreadID?) async throws -> Message {
        let group = try DynamiteID.group(conversation)
        // Marker-free text plus our own FORMAT_DATA annotations, which the server keeps only with accept_format_annotations (Google Chat's send path).
        // A chip the draft held (written elsewhere) goes with it, as when saving the draft.
        let extras = draft.serverDraftID.flatMap { draftExtras[$0] }.map { old in old.annotations.compactMap { Self.relocated($0, from: old.text, to: draft.text) } } ?? []
        let chips = draft.serverDraftID.flatMap { draftExtras[$0]?.annotations } ?? []
        let formats = DynamiteMapper.annotations(Self.sendable(draft.formatting, besides: chips)), formatted = !formats.isEmpty
        // Uploaded files (picked GIFs too) ride in the same field 3, as UPLOAD_METADATA chips.
        let uploads = draft.uploads.compactMap(DynamiteMapper.uploadAnnotation)
        guard uploads.count == draft.uploads.count else { throw AuthFailure.malformedProto }
        let annotations = formats + uploads + extras
        do { return try await create(draft, annotations: annotations, formatted: formatted, in: conversation, group: group, thread: thread) }
        catch {
            // The id is derived from the local id, so a retry whose first attempt reached the server is refused as a duplicate;
            // if that message has already arrived (pushed or loaded), the send did happen.
            let own = DynamiteID.messageID(for: draft.localID)
            let id = DynamiteID.message(conversation, topic: try thread.map(DynamiteID.topic(of:)) ?? own, message: own)
            if let sent = thread.flatMap({ threads[$0]?.first { $0.id == id } }) ?? heads[Self.topicKey(id)].flatMap({ $0.id == id ? $0 : nil }) {
                return sent
            }
            throw error
        }
    }

    func sendMeetLink(in conversation: ConversationID) async throws -> Message {
        let group = try DynamiteID.group(conversation)
        let made: Dynamite_CreateVideoCallResponse = try await rpc("create_video_call", Dynamite_CreateVideoCallRequest.with {
            $0.requestHeader = DynamiteClient.header; $0.groupID = group
        })
        guard made.hasAnnotation else { throw AuthFailure.malformedProto }
        return try await create(MessageDraft(text: "", localID: UUID().uuidString), annotations: [made.annotation], formatted: false,
                                in: conversation, group: group, thread: nil)
    }

    /// No HTTP cache: Google Chat gives a picture a new URL on every load, so none would ever be reused; `ImageCache`
    /// keeps pictures by message instead.
    static func mediaConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 60
        config.urlCache = nil
        return config
    }

    /// Links the message or draft already has as annotations of its own (a space chip, a link Google Chat detected or one
    /// sent before) show as links in the composer: they go as those annotations (or not at all, once their text is gone),
    /// never again as new links.
    static func sendable(_ formatting: [TextStyleRange], besides chips: [Dynamite_Annotation]) -> [TextStyleRange] {
        let chipLinks = Set(chips.compactMap { chip -> URL? in
            switch chip.metadata {
            case .groupMetadata(let group)?: DynamiteID.conversation(group.groupID).map(ChatLink.url)
            case .urlMetadata(let link)?: URL(string: link.url.url)
            default: nil
            }
        })
        let chipRooms = Set(chips.compactMap { chip -> ConversationID? in
            guard case .groupMetadata(let group)? = chip.metadata else { return nil }
            return DynamiteID.conversation(group.groupID)
        })
        return formatting.filter { range in
            switch range.style {
            case .link(let url): !chipLinks.contains(url)
            case .chip(let room, _, _): !chipRooms.contains(room)
            default: true
            }
        }
    }

    private func create(_ draft: MessageDraft, annotations: [Dynamite_Annotation], formatted: Bool, in conversation: ConversationID,
                        group: Dynamite_GroupId, thread: ThreadID?) async throws -> Message {
        let proto: Dynamite_Message
        let quoted = try draft.quoting.flatMap(DynamiteMapper.quotedRef)
        // The draft this message was: Google Chat names it so the server drops it with the send.
        let unsent = try draft.serverDraftID.map { try DynamiteMapper.unsentID($0, conversation: conversation, thread: thread) }
        if let thread {
            let topic = try DynamiteID.topic(of: thread)
            let request = Dynamite_CreateMessageRequest.with { r in
                r.requestHeader = DynamiteClient.header
                r.parentID.topicID.topicID = topic
                r.parentID.topicID.groupID = group
                r.textBody = draft.text
                r.messageID = DynamiteID.messageID(for: draft.localID)
                r.annotations = annotations
                if formatted { r.messageInfo.acceptFormatAnnotations = true }
                if let quoted { r.messageInfo.quotedMessage = quoted }
                if let unsent { r.messageInfo.unsentMessageID = unsent }
            }
            proto = (try await rpc("create_message", request) as Dynamite_CreateMessageResponse).message
        } else {
            let request = Dynamite_CreateTopicRequest.with { r in
                r.requestHeader = DynamiteClient.header
                r.groupID = group
                r.textBody = draft.text
                r.topicAndMessageID = DynamiteID.messageID(for: draft.localID)
                r.historyV2 = true
                r.annotations = annotations
                r.messageInfo.acceptFormatAnnotations = formatted
                if let quoted { r.messageInfo.quotedMessage = quoted }
                if let unsent { r.messageInfo.unsentMessageID = unsent }
            }
            let response: Dynamite_CreateTopicResponse = try await rpc("create_topic", request)
            guard let first = response.topic.replies.first else { throw AuthFailure.malformedProto }
            proto = first
        }
        var placed = place(proto, in: conversation, isHead: thread == nil)   // a reply never becomes the head of a thread not loaded here
        guard !placed.isEmpty else { throw AuthFailure.malformedProto }
        placed[0].threadID = thread
        placed.dropFirst().forEach { continuation.yield(.messageUpserted($0)) }   // the head's new reply count
        return placed[0]
    }

    /// Google Chat's main composer types into the group, a thread's reply box into its topic.
    func sendTyping(conversation: ConversationID, thread: ThreadID?) async throws {
        let group = try DynamiteID.group(conversation)
        let request = try Dynamite_SetTypingStateRequest.with { r in
            r.requestHeader = DynamiteClient.header
            r.state = .typing
            if let thread { r.context.topicID = try .with { $0.topicID = try DynamiteID.topic(of: thread); $0.groupID = group } }
            else { r.context.groupID = group }
        }
        let _: Dynamite_SetTypingStateResponse = try await rpc("set_typing_state", request)
    }
    func watch(_ conversations: Set<ConversationID>) async {
        watched = conversations
        await realtimeChannel?.subscribe(conversations)
    }
    /// `get_user_presence`: 1 is active, any other value away; DND wins. Self is never asked for.
    func fetchPresence(_ ids: [String]) async throws {
        let ids = ids.filter { !$0.isEmpty && $0 != selfID }
        guard !ids.isEmpty else { return }
        let request = Dynamite_GetUserPresenceRequest.with { r in
            r.requestHeader = DynamiteClient.header
            r.userIds = ids.map { id in .with { $0.id = id } }
        }
        let response: Dynamite_GetUserPresenceResponse = try await rpc("get_user_presence", request)
        for presence in response.userPresences where !presence.userID.id.isEmpty {
            let state: Presence = presence.dndState == .dnd || presence.userStatus.dndSettings.dndState == .dnd ? .doNotDisturb
                : presence.presence == .active ? .available : .away
            continuation.yield(.presenceChanged(presence.userID.id, state, status: DynamiteMapper.customStatus(presence.userStatus)))
        }
    }
    /// Readers and how far each has read; ours is left out, since only others' receipts are shown.
    private func receipts(_ set: Dynamite_ReadReceiptSet, in conversation: ConversationID) {
        let reads = set.readReceipts.filter { !$0.user.userID.id.isEmpty && $0.user.userID.id != selfID }
            .map { ($0.user.userID.id, DynamiteMapper.date($0.lastReadTimestampMicros)) }
        continuation.yield(.readReceiptsChanged(conversation, Dictionary(reads, uniquingKeysWith: max), enabled: set.hasEnabled ? set.enabled : nil))
    }

    /// Others compare this time with server create times to show our read receipt,
    /// so it is the newest message's time, never the Mac's clock unless nothing is loaded, and it only moves forward.
    func markRead(_ conversation: ConversationID) async throws {
        let time = max(newest[conversation] ?? Int64(Date.now.timeIntervalSince1970 * 1_000_000), readUpTo[conversation] ?? 0)
        readUpTo[conversation] = time
        let request = try Dynamite_MarkGroupReadstateRequest.with { r in
            r.requestHeader = DynamiteClient.header
            r.id = try DynamiteID.group(conversation)
            r.lastReadTime = time
        }
        let _: Dynamite_MarkGroupReadstateResponse = try await rpc("mark_group_readstate", request)
        // Google Chat clears a mark-as-unread right after the read time; the read time alone leaves it unread.
        if markedUnread.contains(conversation) {
            try await setUnreadMark(0, conversation)
            markedUnread.remove(conversation)
        }
        continuation.yield(.readStateChanged(conversation, unread: 0))
    }
    /// Just before the newest message, as Google Chat sends it, so that message shows unread.
    func markUnread(_ conversation: ConversationID) async throws {
        let newest = max(newest[conversation] ?? 0, latest[conversation] ?? 0)
        try await setUnreadMark((newest > 0 ? newest : Int64(Date.now.timeIntervalSince1970 * 1_000_000)) - 1, conversation)
        markedUnread.insert(conversation)
    }
    private func setUnreadMark(_ time: Int64, _ conversation: ConversationID) async throws {
        let _: Dynamite_SetMarkAsUnreadTimestampResponse = try await rpc("set_mark_as_unread_timestamp", try Dynamite_SetMarkAsUnreadTimestampRequest.with { r in
            r.requestHeader = DynamiteClient.header
            r.groupID = try DynamiteID.group(conversation)
            r.markAsUnreadTimestamp = time
        })
    }
    func setPinned(_ pinned: Bool, conversation: ConversationID) async throws {
        let _: Dynamite_StarGroupResponse = try await rpc("star_group", try Dynamite_StarGroupRequest.with { r in
            r.requestHeader = DynamiteClient.header
            r.groupID = try DynamiteID.group(conversation)
            r.starred = pinned
        })
    }
    /// Mute is separate from the notification level, which is resent as the sidebar last reported it.
    func setMuted(_ muted: Bool, conversation: ConversationID) async throws {
        let response: Dynamite_UpdateGroupNotificationSettingsResponse = try await rpc("update_group_notification_settings",
            try Dynamite_UpdateGroupNotificationSettingsRequest.with { r in
                r.requestHeader = DynamiteClient.header
                r.groupID = try DynamiteID.group(conversation)
                r.notificationSettings.level = notifyLevel[conversation] ?? .notifyAlways
                r.notificationSettings.muteSettings.state = muted ? .muted : .unmuted
            })
        if response.notificationSettings.hasLevel { notifyLevel[conversation] = response.notificationSettings.level }
    }
    /// The same request as mute, as Google Chat's settings screen sends it: the new level with the mute state unchanged.
    func setNotificationLevel(_ level: NotificationLevel, muted: Bool, conversation: ConversationID) async throws {
        let _: Dynamite_UpdateGroupNotificationSettingsResponse = try await rpc("update_group_notification_settings",
            try Dynamite_UpdateGroupNotificationSettingsRequest.with { r in
                r.requestHeader = DynamiteClient.header
                r.groupID = try DynamiteID.group(conversation)
                r.notificationSettings.level = DynamiteMapper.wire(level)
                r.notificationSettings.muteSettings.state = muted ? .muted : .unmuted
            })
        notifyLevel[conversation] = DynamiteMapper.wire(level)
    }
    /// Removes my own membership, as Google Chat leaves a space.
    func leave(_ conversation: ConversationID) async throws {
        let response: Dynamite_RemoveMembershipsResponse = try await rpc("remove_memberships", try Dynamite_RemoveMembershipsRequest.with { r in
            r.requestHeader = DynamiteClient.header
            r.memberIds = [.with { $0.userID.id = selfID }]
            r.groupID = try DynamiteID.group(conversation)
        })
        if response.results.contains(where: \.hasFailureReason) { throw DynamiteError.leaveRefused }
    }

    func edit(_ id: MessageID, text: String, formatting: [TextStyleRange] = []) async throws {
        let request = try Dynamite_EditMessageRequest.with { r in
            r.requestHeader = DynamiteClient.header
            r.messageID = try DynamiteID.protoMessageID(id)
            r.textBody = text
            // Google Chat edits only the text: the rest of the message's annotations go back as they are, or the server drops them.
            let formats = DynamiteMapper.annotations(Self.sendable(formatting, besides: attached[id]?.annotations ?? []))
            r.annotations = formats + (attached[id].map { old in old.annotations.filter { Self.survives($0, from: old.text, to: text) } } ?? [])
            r.messageInfo.acceptFormatAnnotations = !formats.isEmpty
        }
        if attached[id] == nil { log.notice("Editing a message not loaded here: any attachments it has are not re-sent") }
        let response: Dynamite_EditMessageResponse = try await rpc("edit_message", request)
        let conversation = String(id.split(separator: "/").prefix(2).joined(separator: "/"))
        saw([response.message], in: conversation)
        if let thread = unloadedThread(of: response.message, in: conversation),
           var message = DynamiteMapper.message(response.message, in: conversation, selfID: selfID, people: people) {
            message.threadID = thread
            continuation.yield(.messageUpserted(message))
        } else {
            place(response.message, in: conversation).forEach { continuation.yield(.messageUpserted($0)) }
        }
    }
    func delete(_ id: MessageID) async throws {
        let request = try Dynamite_DeleteMessageRequest.with { r in
            r.requestHeader = DynamiteClient.header
            r.messageID = try DynamiteID.protoMessageID(id)
        }
        let _: Dynamite_DeleteMessageResponse = try await rpc("delete_message", request)
        deleted(id)
    }
    func setReaction(_ emoji: String, custom: CustomEmoji?, on id: MessageID, present: Bool) async throws {
        let request = try Dynamite_UpdateReactionRequest.with { r in
            r.requestHeader = DynamiteClient.header
            r.messageID = try DynamiteID.protoMessageID(id)
            r.emoji = DynamiteMapper.emoji(emoji, custom: custom)
            r.option = present ? .add : .remove
        }
        let _: Dynamite_UpdateReactionResponse = try await rpc("update_reaction", request)
        // Shown now; the server's BATCH_REACTIONS_UPDATED that follows re-sends this emoji's count.
        update(id) { [selfID] in $0.reactions = Self.toggled($0.reactions, emoji, custom, by: selfID, present: present) }
    }
    /// `list_reactors` as Google Chat's reactor list sends it: one emoji, 100 people, no paging.
    func reactors(of id: MessageID, emoji: String, custom: CustomEmoji?) async throws -> [Person] {
        let request = try Dynamite_ListReactorsRequest.with { r in
            r.requestHeader = DynamiteClient.header
            r.messageID = try DynamiteID.protoMessageID(id)
            r.emoji = DynamiteMapper.emoji(emoji, custom: custom)
            r.pageSize = 100
        }
        let response: Dynamite_ListReactorsResponse = try await rpc("list_reactors", request)
        let ids = response.reactors.map(\.id).filter { !$0.isEmpty }
        await resolve(ids)
        return ids.map { people[$0] ?? Person(id: $0, name: "Unknown") }
    }
    /// Changes a loaded head or reply and emits it; a message Parley never loaded is left alone.
    /// A thread loaded on its own (opened from Home) holds its replies without its head: its id is the topic's.
    private func update(_ id: MessageID, _ change: (inout Message) -> Void) {
        let topic = Self.topicKey(id)
        let headID = heads[topic]?.id ?? topic + "/" + (topic.split(separator: "/").last ?? "")
        if var head = heads[topic], head.id == id {
            change(&head)
            heads[topic] = head
            continuation.yield(.messageUpserted(head))
        } else if let index = threads[headID]?.firstIndex(where: { $0.id == id }), var reply = threads[headID]?[index] {
            change(&reply)
            threads[headID]?[index] = reply
            continuation.yield(.messageUpserted(reply))
        }
    }
    private static func toggled(_ reactions: [Reaction], _ emoji: String, _ custom: CustomEmoji?, by person: String, present: Bool) -> [Reaction] {
        var reactions = reactions
        if let index = reactions.firstIndex(where: { $0.emoji == emoji && $0.custom?.id == custom?.id }) {
            if present { reactions[index].people.insert(person) }
            else if reactions[index].people.remove(person) == nil,   // known only by count: one placeholder goes instead
                    let filler = reactions[index].people.first(where: { $0.hasPrefix("reactor-") }) {
                reactions[index].people.remove(filler)
            }
        } else if present {
            reactions.append(Reaction(emoji: emoji, people: [person], custom: custom))
        }
        return reactions.filter { !$0.people.isEmpty }
    }
    func searchMessages(_ query: String, cursor: String?) async throws -> SearchPage {
        let request = Dynamite_SearchMessagesV2Request.with { r in
            r.requestHeader = DynamiteClient.header
            r.size = 20
            if let cursor { r.cursor = cursor }
            r.filter = .init()   // Google Chat always sends the filter, empty when unfiltered
            r.query = query
        }
        let response: Dynamite_SearchMessagesV2Response = try await rpc("search_messages_v2", request)
        let protos = response.results.items.map(\.message)
        await resolve(messages: protos)
        return SearchPage(messages: protos.compactMap(located), cursor: response.cursor.isEmpty ? nil : response.cursor)
    }
    /// A message from anywhere (search, shortcuts) in its conversation, pointing at its thread when it is a reply.
    private func located(_ proto: Dynamite_Message) -> Message? {
        guard let conversation = DynamiteID.conversation(proto.id.parentID.topicID.groupID),
              var message = DynamiteMapper.message(proto, in: conversation, selfID: selfID, people: people) else { return nil }
        if let head = heads[Self.topicKey(message.id)], head.id != message.id { message.threadID = head.id }
        else { message.threadID = unloadedThread(of: proto, in: conversation) }
        return message
    }
    /// `apply_message_label` / `remove_message_label` with the STAR label, as Google Chat's Star and Unstar send them.
    func setStarred(_ starred: Bool, on id: MessageID) async throws {
        let request = try Dynamite_MessageLabelRequest.with { r in
            r.requestHeader = DynamiteClient.header
            r.messageID = try DynamiteID.protoMessageID(id)
            r.label.type = .star
        }
        if starred { let _: Dynamite_ApplyMessageLabelResponse = try await rpc("apply_message_label", request) }
        else { let _: Dynamite_RemoveMessageLabelResponse = try await rpc("remove_message_label", request) }
        update(id) { $0.starred = starred }
    }
    /// `click_card`, as Google Chat sends a card button's action: the message, the action as the button carried it, every
    /// input of the card. The app answers with the message, its card updated.
    func clickCard(_ id: MessageID, action: Data, inputs: [Card.Input]) async throws -> Message? {
        let request = try Dynamite_ClickCardRequest.with { r in
            r.messageID = try DynamiteID.protoMessageID(id)
            r.action = action
            r.formInputs = inputs.map { input in .with { $0.name = input.name; $0.value = input.value; $0.field4 = 1 } }
            r.field4 = ""
            r.requestHeader = DynamiteClient.header
        }
        let response: Dynamite_ClickCardResponse = try await rpc("click_card", request)
        guard response.hasMessage else { return nil }
        let conversation = String(id.split(separator: "/").prefix(2).joined(separator: "/"))
        return place(response.message, in: conversation).first
    }
    /// A Mentions or Starred shortcut. Google Chat keeps each as a hidden space ("Shortcut-MENTIONS", "Shortcut-STARRED")
    /// of copies, each naming its original message; `paginated_world` with the shortcut's section returns that space,
    /// and its topics page like any conversation's. `cursor`: the oldest topic's sort time.
    func shortcut(_ shortcut: Shortcut, cursor: String?) async throws -> SearchPage {
        guard shortcut != .home else { return SearchPage(messages: [], cursor: nil) }   // Home is built from held conversations
        guard shortcut != .drafts else { return SearchPage(messages: [], cursor: nil) }   // drafts come from `drafts()`
        // Personal (non-Workspace) accounts have no shortcut spaces: Google refuses the section, and Google Chat shows the list empty.
        let space: Dynamite_GroupId
        do { space = try await shortcutSpace(shortcut) }
        catch AuthFailure.http(403) { return SearchPage(messages: [], cursor: nil) }
        catch DynamiteError.notYetSupported { return SearchPage(messages: [], cursor: nil) }
        let request = Dynamite_ListTopicsRequest.with { r in
            r.requestHeader = DynamiteClient.header
            r.groupID = space
            r.field11 = 2
            r.pageSizeForTopics = 30
            r.fetchOptions = [.topicMetadata]
            r.pageSizeForUnreadReplies = 20
            r.pageSizeForReadReplies = 20
            if let cursor, let anchor = Int64(cursor) { r.filter.olderThan = anchor }
        }
        let response: Dynamite_ListTopicsResponse = try await rpc("list_topics", request)
        let protos = response.topics.flatMap(\.replies).compactMap { copy -> Dynamite_Message? in
            guard copy.shortcutSource.ref.hasMessageID else { return nil }
            var original = copy
            original.id = copy.shortcutSource.ref.messageID
            return original
        }
        await resolve(messages: protos)
        var seen: Set<MessageID> = []
        let messages = protos.compactMap(located)
            .filter { seen.insert($0.id).inserted }
            .map { message in var message = message; if shortcut == .starred { message.starred = true }; return message }
            .sorted { $0.createdAt > $1.createdAt }
        let oldest = response.topics.map(\.sortTime).filter { $0 > 0 }.min()
        return SearchPage(messages: messages, cursor: response.containsFirstTopic ? nil : oldest.map(String.init))
    }
    private var shortcutSpaces: [Shortcut: Dynamite_GroupId] = [:]
    private func shortcutSpace(_ shortcut: Shortcut) async throws -> Dynamite_GroupId {
        if let space = shortcutSpaces[shortcut] { return space }
        let kind: Dynamite_WorldFilter.ShortcutType = shortcut == .mentions ? .mentions : .starred
        let request = Dynamite_PaginatedWorldRequest.with { r in
            r.requestHeader = DynamiteClient.header
            r.worldSectionRequests = [.with { s in
                s.pageSize = 30
                s.worldFilter = .with { $0.groupType = .room; $0.shortcutTypes = [kind] }
                s.field7 = 2
            }]
        }
        let response: Dynamite_PaginatedWorldResponse = try await rpc("paginated_world", request)
        guard let space = (response.worldItems + response.worldSectionResponses.flatMap(\.worldItems)).first?.groupID,
              DynamiteID.conversation(space) != nil else { throw DynamiteError.notYetSupported("\(shortcut.title)") }
        shortcutSpaces[shortcut] = space
        return space
    }

    // Server drafts are Google Chat's unsent messages of type DRAFT. Their four RPCs carry the request header at field 1.
    /// `list_unsent_messages` as Google Chat's start-up asks for drafts: filter {type DRAFT, 5: 0}, an empty paging field,
    /// then each page's token.
    // ponytail: stops after 10 pages; raise it if anyone keeps that many drafts.
    func drafts() async throws -> [ServerDraft] {
        var drafts: [ServerDraft] = [], token: String?
        for _ in 0..<10 {
            let request = Dynamite_ListUnsentMessagesRequest.with { r in
                r.requestHeader = DynamiteClient.header
                r.paging = .init()
                if let token { r.paging.pageToken = token }
                r.filter.type = .draft
                r.filter.scope = 0
            }
            let response: Dynamite_ListUnsentMessagesResponse = try await rpc("list_unsent_messages", request)
            response.unsentMessages.forEach(keepUneditable)
            drafts += response.unsentMessages.compactMap(DynamiteMapper.draft)
            guard !response.nextPageToken.isEmpty, response.nextPageToken != token else { break }
            token = response.nextPageToken
        }
        return drafts
    }
    /// As Google Chat's composer saves: `create_unsent_message` with a client-chosen id, type DRAFT and a new mutation id;
    /// later `update_unsent_message` with the whole text and the mask Google Chat sends (mutation id, text, annotations, quote).
    func saveDraft(_ draft: ServerDraft) async throws -> ServerDraft {
        let creating = draft.id.isEmpty
        let unsent = try Dynamite_UnsentMessage.with { m in
            m.id = try DynamiteMapper.unsentID(creating ? DynamiteID.messageID(for: UUID().uuidString) : draft.id,
                                               conversation: draft.conversationID, thread: draft.threadID)
            m.textBody = draft.text
            let extras = draftExtras[draft.id].map { old in old.annotations.compactMap { Self.relocated($0, from: old.text, to: draft.text) } } ?? []
            m.annotations = DynamiteMapper.annotations(Self.sendable(draft.formatting, besides: draftExtras[draft.id]?.annotations ?? [])) + extras
            if creating { m.type = .draft }
            m.mutationID = UUID().uuidString   // uppercase, as Google Chat sends it
        }
        let saved: Dynamite_UnsentMessage
        if creating {
            let response: Dynamite_CreateUnsentMessageResponse = try await rpc("create_unsent_message", Dynamite_CreateUnsentMessageRequest.with {
                $0.requestHeader = DynamiteClient.header; $0.unsentMessage = unsent
            })
            saved = response.unsentMessage
        } else {
            let response: Dynamite_UpdateUnsentMessageResponse = try await rpc("update_unsent_message", Dynamite_UpdateUnsentMessageRequest.with {
                $0.requestHeader = DynamiteClient.header; $0.unsentMessage = unsent; $0.updateMask.fields = [9, 4, 5, 6]
            })
            saved = response.unsentMessage
        }
        log.notice("draft \(creating ? "created" : "updated", privacy: .public)")
        var result = draft
        result.id = unsent.id.id
        draftExtras[result.id] = draftExtras[draft.id].map { _ in (draft.text, unsent.annotations.filter(Self.uneditable)) }
        result.updatedAt = DynamiteMapper.time(saved.updateTime) ?? .now
        return result
    }
    /// What a draft written elsewhere holds that Parley's composer can't edit (a space chip, a link preview), by draft id,
    /// with the text it was laid over: saving again puts it back. Formatting, mentions and custom emoji are rebuilt instead.
    private var draftExtras: [String: (text: String, annotations: [Dynamite_Annotation])] = [:]
    private func keepUneditable(_ unsent: Dynamite_UnsentMessage) {
        let kept = unsent.annotations.filter(Self.uneditable)
        draftExtras[unsent.id.id] = kept.isEmpty ? nil : (unsent.textBody, kept)
    }
    private static func uneditable(_ annotation: Dynamite_Annotation) -> Bool {
        switch annotation.metadata {
        case .formatMetadata, .userMentionMetadata, .customEmojiMetadata: false
        default: true
        }
    }
    /// `annotation` over the same text in `new`: in place, else moved to that text's only occurrence; nil when it's gone.
    static func relocated(_ annotation: Dynamite_Annotation, from old: String, to new: String) -> Dynamite_Annotation? {
        if survives(annotation, from: old, to: new) { return annotation }
        let start = Int(annotation.startIndex), end = start + Int(annotation.length), old = Array(old.utf16), new = Array(new.utf16)
        guard start >= 0, end <= old.count, end > start else { return nil }
        let text = Array(old[start..<end])
        let found = new.indices.filter { $0 + text.count <= new.count && Array(new[$0..<($0 + text.count)]) == text }
        guard found.count == 1 else { return nil }
        var moved = annotation
        moved.startIndex = Int32(found[0])
        return moved
    }
    func deleteDraft(_ draft: ServerDraft) async throws {
        let request = try Dynamite_DeleteUnsentMessageRequest.with {
            $0.requestHeader = DynamiteClient.header
            $0.id = try DynamiteMapper.unsentID(draft.id, conversation: draft.conversationID, thread: draft.threadID)
        }
        let _: Dynamite_DeleteUnsentMessageResponse = try await rpc("delete_unsent_message", request)
        log.notice("draft deleted")
    }

    /// get_attachment_url answers with a redirect to a content host, which `WebSessionAuthorizer` treats as a lost session,
    /// so media follows redirects here: HTTPS only, cookies re-scoped per hop by `SessionCookie` (Google hosts only), no XSRF.
    func attachmentData(_ attachment: Attachment, thumbnail: Bool) async throws -> Data {
        guard var url = thumbnail ? attachment.thumbnailURL ?? attachment.url : attachment.url ?? attachment.thumbnailURL else {
            throw DynamiteError.notYetSupported("This attachment")
        }
        guard let stored = try vault.read(), let credentials = try? JSONDecoder().decode(WebCredentials.self, from: stored) else {
            throw AuthFailure.signInRequired
        }
        for _ in 0..<5 {
            guard url.scheme == "https", url.user == nil, url.password == nil else { throw AuthFailure.invalidDestination }
            if url.host() == "accounts.google.com" { throw AuthFailure.signInRequired }
            var request = URLRequest(url: url)
            let cookies = SessionCookie.header(credentials.cookies, for: url)
            if !cookies.isEmpty { request.setValue(cookies, forHTTPHeaderField: "Cookie") }
            request.setValue(credentials.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await media.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw AuthFailure.unexpectedResponse }
            switch response.statusCode {
            case 200: return data
            case 300..<400:
                guard let next = response.value(forHTTPHeaderField: "Location").flatMap({ URL(string: $0, relativeTo: url)?.absoluteURL }) else {
                    throw AuthFailure.unexpectedResponse
                }
                url = next
            default: throw AuthFailure.http(response.statusCode)
            }
        }
        throw AuthFailure.unexpectedResponse
    }

    /// A Scotty resumable upload over the web session: `start` on chat.google.com/uploads,
    /// then one `upload, finalize` PUT to the session URL it returns. Both go through `WebSessionAuthorizer`, so they carry the
    /// session's cookies and XSRF token and only ever reach https://chat.google.com. The reply is a base64 UploadMetadata,
    /// kept whole as the attachment's `uploadToken` for `send`.
    func upload(_ attachment: Attachment, to conversation: ConversationID, thread: ThreadID?) async throws -> Attachment {
        guard let file = attachment.url, file.isFileURL else { throw DynamiteError.notYetSupported("This attachment") }
        let group = try DynamiteID.group(conversation)
        // ponytail: the whole file in one request (memory-mapped); chunk with `upload` commands if 200 MB proves too much.
        let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
        guard !bytes.isEmpty else { throw AttachmentError.empty(attachment.name) }
        guard bytes.count <= Attachment.maxUploadBytes else { throw AttachmentError.tooLarge(attachment.name) }
        var query = [URLQueryItem(name: "group_id", value: group.spaceID.spaceID.isEmpty ? group.dmID.dmID : group.spaceID.spaceID)]
        if let thread { query.append(URLQueryItem(name: "topic_id", value: try DynamiteID.topic(of: thread))) }
        var components = URLComponents(string: "https://chat.google.com/uploads")!
        components.queryItems = query
        var start = URLRequest(url: components.url!)
        start.httpMethod = "POST"
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue(attachment.name.filter { $0 != "\r" && $0 != "\n" }, forHTTPHeaderField: "X-Goog-Upload-File-Name")
        start.setValue(String(bytes.count), forHTTPHeaderField: "X-Goog-Upload-Content-Length")
        if !attachment.contentType.isEmpty { start.setValue(attachment.contentType, forHTTPHeaderField: "X-Goog-Upload-Content-Type") }
        let (_, started) = try await authorized(start)
        guard started.value(forHTTPHeaderField: "X-Goog-Upload-Status")?.lowercased() == "active",
              let session = started.value(forHTTPHeaderField: "X-Goog-Upload-URL").flatMap(URL.init(string:)) else {
            throw AuthFailure.unexpectedResponse
        }
        var put = URLRequest(url: session)
        put.httpMethod = "PUT"
        put.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        put.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        put.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        put.httpBody = bytes
        let (body, finished) = try await authorized(put)
        guard finished.value(forHTTPHeaderField: "X-Goog-Upload-Status")?.lowercased() == "final",
              let metadata = Data(base64Encoded: body, options: .ignoreUnknownCharacters),
              let decoded = try? Dynamite_UploadMetadata(serializedBytes: metadata), !decoded.attachmentToken.isEmpty else {
            throw AuthFailure.malformedProto
        }
        var uploaded = attachment
        uploaded.uploadToken = metadata.base64EncodedString()
        return uploaded
    }
    /// Like `rpc`: a lost session surfaces as Signed out.
    private func authorized(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do { return try await authorizer.data(for: request) }
        catch AuthFailure.signInRequired {
            continuation.yield(.connectionChanged(.signedOut))
            throw AuthFailure.signInRequired
        }
    }

    private static let repliesPerPage = 30

    /// A thread's replies, newest page first, then older pages, all via list_messages.
    /// list_topics' replies aren't used here: for unread threads they are the oldest unread ones, not the newest.
    private func threadPage(_ thread: ThreadID, in conversation: ConversationID, older: Bool) async throws -> MessagePage {
        if older, threadStart.contains(thread) { return MessagePage(messages: [], hasMore: false) }
        let held = older ? threads[thread] ?? [] : []
        let anchor = held.map { Int64(($0.createdAt.timeIntervalSince1970 * 1_000_000).rounded()) }.min()
        let request = try Dynamite_ListMessagesRequest.with { r in
            r.requestHeader = DynamiteClient.header
            r.parentID.topicID.topicID = try DynamiteID.topic(of: thread)
            r.parentID.topicID.groupID = try DynamiteID.group(conversation)
            r.pageSize = Int32(Self.repliesPerPage)
            r.filter.olderThan = anchor ?? 9_007_199_254_740_991   // 2^53−1: the newest replies (the LATEST anchor)
        }
        let response: Dynamite_ListMessagesResponse = try await rpc("list_messages", request)
        saw(response.messages, in: conversation)
        await resolve(messages: response.messages)
        let known = Set(held.map(\.id))
        let fetched = response.messages
            .compactMap { DynamiteMapper.message($0, in: conversation, selfID: selfID, people: people) }
            .filter { $0.id != thread && !known.contains($0.id) }   // the anchor may be inclusive
            .map { var reply = $0; reply.threadID = thread; return reply }
            .sorted { $0.createdAt < $1.createdAt }
        threads[thread] = (fetched + held).sorted { $0.createdAt < $1.createdAt }
        let done = response.containsFirstMessage || fetched.isEmpty || response.messages.count < Self.repliesPerPage
        if done { threadStart.insert(thread) } else { threadStart.remove(thread) }
        return MessagePage(messages: fetched, hasMore: !done)
    }

    /// Applies one pushed event. Internal so tests can drive it without a channel.
    func handle(_ response: Dynamite_StreamEventsResponse) async { await apply(response.event) }

    /// `live: false` for events replayed by a catch-up, which update state but announce nothing.
    private func apply(_ event: Dynamite_Event, live: Bool = true) async {
        // Events carry a user or a group revision (a oneof); both are µs timestamps of the last event seen.
        userRevision = max(userRevision, event.userRevision.timestamp, event.groupRevision.timestamp)
        for body in event.bodies {
            switch body.eventType {
            case .sessionReady:
                continuation.yield(.connectionChanged(.connected))
                if readyBefore { await catchUp() }   // the first ready follows a fresh load; later ones follow a gap
                readyBefore = true
            case .messagePosted, .messageUpdated:
                let proto = body.messagePosted.message
                guard !proto.id.messageID.isEmpty,
                      let conversation = DynamiteID.conversation(event.groupID) ?? DynamiteID.conversation(proto.id.parentID.topicID.groupID) else { continue }
                if live, conversation.hasPrefix("dm/") { await refreshSender(proto.creator.userID.id) }   // DM invites carry placeholders
                await resolve(messages: [proto])
                let placed = place(proto, in: conversation, isHead: body.messagePosted.hasIsHead ? body.messagePosted.isHead : nil)
                if placed.isEmpty {   // tombstone
                    deleted(DynamiteID.message(conversation, topic: proto.id.parentID.topicID.topicID, message: proto.id.messageID))
                }
                placed.forEach { continuation.yield(.messageUpserted($0)) }
            case .messageDeleted:
                let id = body.messageDeleted.messageID
                guard !id.messageID.isEmpty,
                      let conversation = DynamiteID.conversation(event.groupID) ?? DynamiteID.conversation(id.parentID.topicID.groupID) else { continue }
                deleted(DynamiteID.message(conversation, topic: id.parentID.topicID.topicID, message: id.messageID))
            case .groupUpdated, .membershipChanged, .groupDeleted, .groupNotificationSettingsUpdated:
                await conversationChanged(event, body)
            case .topicLabelApplied, .topicLabelRemoved:
                let label = body.topicLabel, topic = label.topicID
                guard label.label.type == .threadFollowed, !topic.topicID.isEmpty,
                      let conversation = DynamiteID.conversation(topic.groupID) ?? DynamiteID.conversation(event.groupID) else { continue }
                continuation.yield(.threadFollowChanged(DynamiteID.message(conversation, topic: topic.topicID, message: topic.topicID),
                                                        following: body.eventType == .topicLabelApplied))
            case .messageReacted:   // one person's reaction added or removed
                let reacted = body.messageReaction, id = reacted.messageID
                log.notice("event: one reaction \(reacted.option == .remove ? "removed" : "added", privacy: .public)")
                guard !id.messageID.isEmpty, !reacted.reactor.id.isEmpty, let (emoji, custom) = DynamiteMapper.reactionKey(reacted.emoji),
                      let conversation = DynamiteID.conversation(event.groupID) ?? DynamiteID.conversation(id.parentID.topicID.groupID) else { continue }
                let message = DynamiteID.message(conversation, topic: id.parentID.topicID.topicID, message: id.messageID)
                update(message) {
                    $0.reactions = Self.toggled($0.reactions, emoji, custom, by: reacted.reactor.id, present: reacted.option != .remove)
                }
                if live { continuation.yield(.reacted(message, emoji: emoji, by: reacted.reactor.id, added: reacted.option != .remove)) }
            case .batchReactionsUpdated:   // whole summaries with partial reactor lists: no reliable who-added-what, so no .reacted
                log.notice("event: reaction summary")
                let id = body.batchReactionsUpdated.messageID
                guard !id.messageID.isEmpty,
                      let conversation = DynamiteID.conversation(event.groupID) ?? DynamiteID.conversation(id.parentID.topicID.groupID) else { continue }
                let summaries = body.batchReactionsUpdated.reactionSummaries
                update(DynamiteID.message(conversation, topic: id.parentID.topicID.topicID, message: id.messageID)) { [selfID] in
                    $0.reactions = DynamiteMapper.reactions(summaries, onto: $0.reactions, selfID: selfID)
                }
            case .typingStateChanged:
                let typing = body.typingStateChanged, topic = typing.context.topicID
                guard !typing.userID.id.isEmpty, typing.userID.id != selfID,   // Google Chat drops its own
                      let conversation = [typing.context.groupID, topic.groupID, event.groupID].lazy.compactMap(DynamiteID.conversation).first else { continue }
                let thread = topic.topicID.isEmpty ? nil : DynamiteID.message(conversation, topic: topic.topicID, message: topic.topicID)
                continuation.yield(.typingChanged(conversation, thread, typing.userID.id, isTyping: typing.state == .typing))
            case .activityIndicatorChanged:   // Ask Gemini at work: no text means it is thinking
                let activity = body.activityIndicatorChanged, topic = activity.context.topicID
                guard !activity.userID.id.isEmpty,
                      let conversation = [activity.context.groupID, topic.groupID, event.groupID].lazy.compactMap(DynamiteID.conversation).first else { continue }
                let thread = topic.topicID.isEmpty ? nil : DynamiteID.message(conversation, topic: topic.topicID, message: topic.topicID)
                let label = activity.state == 2 ? nil : activity.progress.text.isEmpty ? "Thinking" : activity.progress.text
                continuation.yield(.activityChanged(conversation, thread, activity.userID.id, label: label))
            case .readReceiptChanged:
                let changed = body.readReceiptChanged
                guard let conversation = DynamiteID.conversation(changed.groupID) ?? DynamiteID.conversation(event.groupID) else { continue }
                receipts(changed.readReceiptSet, in: conversation)
            case .userStatusUpdatedEvent:
                let status = body.userStatusUpdated.userStatus
                guard !status.userID.id.isEmpty else { continue }
                continuation.yield(.presenceChanged(status.userID.id, status.dndSettings.dndState == .dnd ? .doNotDisturb : nil,
                                                    status: DynamiteMapper.customStatus(status)))
            case .unsentMessageCreated, .unsentMessageUpdated, .unsentMessageDeleted:   // a draft saved or dropped, here or elsewhere
                let unsent = body.unsentMessage.unsentMessage
                log.notice("event: draft \(body.eventType == .unsentMessageCreated ? "created" : body.eventType == .unsentMessageUpdated ? "updated" : "deleted", privacy: .public)")
                if body.eventType == .unsentMessageDeleted {
                    if !unsent.id.id.isEmpty { continuation.yield(.draftDeleted(unsent.id.id)) }
                } else if let draft = DynamiteMapper.draft(unsent) {
                    keepUneditable(unsent)
                    continuation.yield(.draftChanged(draft))
                }
            default: break
            }
        }
    }

    /// A conversation created, renamed, joined, left or deleted elsewhere: gone when we
    /// left it or it was deleted; otherwise its sidebar item, from the event when sent, else from a fresh world read.
    private func conversationChanged(_ event: Dynamite_Event, _ body: Dynamite_EventBody) async {
        if body.eventType == .groupDeleted, !body.groupDeleted.groupIds.isEmpty {
            body.groupDeleted.groupIds.compactMap(DynamiteID.conversation).forEach { continuation.yield(.conversationRemoved($0)) }
            return
        }
        let membership = body.membershipChanged.newMembership
        guard let id = [event.groupID, body.groupUpdated.group.groupID, membership.id.groupID, body.groupNotificationSettingsUpdated.groupID]
            .lazy.compactMap(DynamiteID.conversation).first else { return }
        if body.eventType == .groupDeleted || body.groupUpdated.groupUpdateType == .groupDeleted
            || (membership.id.memberID.userID.id == selfID && membership.membershipState == .memberNotAMember) {
            continuation.yield(.conversationRemoved(id))
            return
        }
        let item: Dynamite_WorldItemLite?
        // A rename pushed an item with the new avatar but no name: a nameless item for a space-style id is read again.
        if event.hasWorldItemLite, DynamiteID.conversation(event.worldItemLite.groupID) == id,
           !event.worldItemLite.roomName.isEmpty || event.worldItemLite.groupID.spaceID.spaceID.isEmpty {
            item = event.worldItemLite
        } else {
            // ponytail: a whole world read per event; use get_group if busy spaces make this chatty.
            do { item = try await worldItems().0.first { DynamiteID.conversation($0.groupID) == id } }
            catch { log.error("paginated_world failed: \(String(describing: type(of: error)), privacy: .public)"); return }
        }
        guard let item else { continuation.yield(.conversationRemoved(id)); return }
        remember(item)
        await resolve(DynamiteMapper.memberIDs(item))
        if let room = DynamiteMapper.conversation(item, selfID: selfID, people: people) { continuation.yield(.conversationUpserted(room)) }
    }

    /// Emits the deletion; a deleted reply also lowers its head's reply count.
    private func deleted(_ id: MessageID) {
        continuation.yield(.messageDeleted(id))
        attached[id] = nil
        let topic = Self.topicKey(id)
        guard var head = heads[topic], head.id != id, let index = threads[head.id]?.firstIndex(where: { $0.id == id }) else { return }
        threads[head.id]?.remove(at: index)
        head.replyCount = max(0, head.replyCount - 1)
        heads[topic] = head
        continuation.yield(.messageUpserted(head))
    }

    /// The first message seen for a topic is its head; later ones are replies that bump the head's count.
    /// A message the server says is not a head is a reply even when its head was never loaded here.
    private func place(_ proto: Dynamite_Message, in conversation: ConversationID, isHead: Bool? = nil) -> [Message] {
        saw([proto], in: conversation)
        guard var message = DynamiteMapper.message(proto, in: conversation, selfID: selfID, people: people) else { return [] }
        let topic = Self.topicKey(message.id)
        if heads[topic] == nil, isHead == false, !proto.id.parentID.topicID.topicID.isEmpty {
            message.threadID = DynamiteID.message(conversation, topic: proto.id.parentID.topicID.topicID, message: proto.id.parentID.topicID.topicID)
            return [message]
        }
        guard var head = heads[topic], head.id != message.id else {
            message.replyCount = heads[topic]?.replyCount ?? 0   // an edited head keeps its count
            heads[topic] = message
            return [message]
        }
        message.threadID = head.id
        if let index = threads[head.id]?.firstIndex(where: { $0.id == message.id }) {
            threads[head.id]?[index] = message
            return [message]
        }
        threads[head.id, default: []].append(message)
        head.replyCount += 1
        heads[topic] = head
        return [message, head]
    }

    /// The channel's state as the app sees it: while polling keeps events coming, a channel that can't hold a session
    /// still counts as connected; a lost session always shows.
    private func channelChanged(_ state: ConnectionState) {
        channelState = state
        if state == .connected || state == .signedOut { continuation.yield(.connectionChanged(state)); return }
        if let lastPoll, ContinuousClock.now - lastPoll < Self.pollInterval * 3 { return }
        continuation.yield(.connectionChanged(state))
    }
    /// One round of polling: the events since the last one, announced as if pushed (notifications included). Events at
    /// or before the revision already seen are skipped, so a replayed one (a reaction toggle) never applies twice.
    @discardableResult
    func poll() async -> Bool {
        let from = userRevision
        do {
            let request = Dynamite_CatchUpUserRequest.with { r in
                r.requestHeader = DynamiteClient.header
                r.range.fromRevisionTimestamp = from
                r.pageSize = 500
                r.cutoffSize = 500
            }
            let response: Dynamite_CatchUpResponse = try await rpc("catch_up_user", request)
            for event in response.events where max(event.userRevision.timestamp, event.groupRevision.timestamp) > from {
                await apply(event, live: true)
            }
            let first = lastPoll == nil
            lastPoll = .now
            if first || channelState != .connected { continuation.yield(.connectionChanged(.connected)) }
            if first { log.notice("Polling for events: the realtime channel is down") }
            return true
        } catch {
            log.error("Polling failed: \(PunctualChannel.reason(error), privacy: .public)")
            return false
        }
    }

    /// Events missed while the channel was down (Google Chat: catch_up_user on every SESSION_READY); else a full resync.
    private func catchUp() async {
        var from = userRevision
        guard from > 0 else { continuation.yield(.resync); return }
        do {
            for _ in 0..<10 {   // ponytail: ≤ 20k events; past that a resync is cheaper anyway
                let request = Dynamite_CatchUpUserRequest.with { r in
                    r.requestHeader = DynamiteClient.header
                    r.range.fromRevisionTimestamp = from
                    r.pageSize = 2000
                    r.cutoffSize = 2000
                }
                let response: Dynamite_CatchUpResponse = try await rpc("catch_up_user", request)
                for event in response.events { await apply(event, live: false) }
                if response.status == .completed { return }
                guard response.status == .paginated, userRevision > from else { break }
                from = userRevision
            }
        } catch {
            log.error("catch_up_user failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        continuation.yield(.resync)
    }

    /// A reply's thread head when Parley never loaded it: a head message's id equals its topic id.
    private func unloadedThread(of proto: Dynamite_Message, in conversation: ConversationID) -> ThreadID? {
        let topic = proto.id.parentID.topicID.topicID
        guard !topic.isEmpty, proto.id.messageID != topic, heads["\(conversation)/\(topic)"] == nil else { return nil }
        return DynamiteID.message(conversation, topic: topic, message: topic)
    }

    private func saw(_ protos: some Sequence<Dynamite_Message>, in conversation: ConversationID) {
        if let time = protos.map(\.createTime).max(), time > newest[conversation] ?? 0 { newest[conversation] = time }
        for proto in protos where !proto.id.messageID.isEmpty {
            let id = DynamiteID.message(conversation, topic: proto.id.parentID.topicID.topicID, message: proto.id.messageID)
            let kept = proto.annotations.filter { annotation in
                switch annotation.metadata {
                case .formatMetadata, .userMentionMetadata, .customEmojiMetadata: false   // rebuilt from the edited text's formatting
                default: true
                }
            }
            attached[id] = kept.isEmpty || proto.deleteTime != 0 ? nil : (proto.textBody, kept)
        }
    }

    /// An annotation with no text range (an upload, a Drive file) always survives an edit; one over the text (a link preview,
    /// a space chip) only while that text is unchanged at the same place, since its range would otherwise point at other text.
    static func survives(_ annotation: Dynamite_Annotation, from old: String, to new: String) -> Bool {
        guard annotation.length > 0 else { return true }
        let start = Int(annotation.startIndex), end = start + Int(annotation.length), old = Array(old.utf16), new = Array(new.utf16)
        return start >= 0 && end <= min(old.count, new.count) && old[start..<end] == new[start..<end]
    }

    private static func topicKey(_ id: MessageID) -> String { String(id[..<(id.lastIndex(of: "/") ?? id.endIndex)]) }

    /// Every RPC goes through here so an expired session surfaces as Signed out wherever it happens.
    private func rpc<Response: SwiftProtobuf.Message>(_ method: String, _ request: some SwiftProtobuf.Message) async throws -> Response {
        do { return try await client.call(method, request) }
        catch AuthFailure.signInRequired {
            continuation.yield(.connectionChanged(.signedOut))
            throw AuthFailure.signInRequired
        } catch AuthFailure.http(let status) {
            log.error("\(method, privacy: .public) returned HTTP \(status, privacy: .public)")
            throw AuthFailure.http(status)
        }
    }

    /// `list_members` as Google Chat's member-list sync sends it: joined members, 100 a page.
    // ponytail: stops after 10 pages (1,000 members); raise it if a bigger space needs mentions of everyone.
    func members(of conversation: ConversationID) async throws -> [Person] {
        let group = try DynamiteID.group(conversation)
        var people: [Person] = [], token: String?
        for _ in 0..<10 {
            let request = Dynamite_ListMembersRequest.with { r in
                r.requestHeader = DynamiteClient.header
                r.groupID = group
                r.memberTypes = [1, 5]
                r.membershipFilter = 4
                r.pageSize = 100
                r.flag8 = true
                if let token { r.pageToken = token }
            }
            let response: Dynamite_ListMembersResponse = try await rpc("list_members", request)
            people += response.members.filter { !$0.user.userID.id.isEmpty }.map { DynamiteMapper.person($0.user) }
            guard !response.nextPageToken.isEmpty else { break }
            token = response.nextPageToken
        }
        let unnamed = people.filter { $0.name == "Unknown" }.map(\.id)
        await resolve(unnamed)   // the page may carry ids only
        for person in people where self.people[person.id] == nil || person.name != "Unknown" { self.people[person.id] = person }
        return people.map { self.people[$0.id] ?? $0 }
    }

    /// `list_custom_emojis` as Google Chat sends it: 100 a page, the first with filters for enabled (and system-disabled)
    /// emoji, later pages only the token. Only enabled ones can be sent.
    // ponytail: stops after 20 pages (2,000 emoji); raise it if an organisation has more.
    func customEmojis() async throws -> [CustomEmoji] {
        var emoji: [CustomEmoji] = [], token: String?
        for _ in 0..<20 {
            let request = Dynamite_ListCustomEmojisRequest.with { r in
                r.requestHeader = DynamiteClient.header
                r.pageSize = 100
                if let token { r.pageToken = token } else { r.filters = Self.customEmojiFilters }
            }
            let response: Dynamite_ListCustomEmojisResponse = try await rpc("list_custom_emojis", request)
            emoji += response.customEmojis.filter { $0.state == .enabled }.compactMap(DynamiteMapper.customEmoji)
            guard !response.nextPageToken.isEmpty, response.nextPageToken != token else { break }
            token = response.nextPageToken
        }
        return emoji
    }
    static let customEmojiFilters: [Dynamite_ListCustomEmojisRequest.Filter] = [
        .with { $0.kind = 2; $0.states.states = [.enabled, .systemDisabled]; $0.operation = 1 },
        .with { $0.kind = 3; $0.states.states = [.enabled]; $0.operation = 1 },
    ]

    /// Dynamite has no directory-wide people search (the official apps ask a separate people service), so this searches everyone
    /// Parley has looked up: sidebar members, senders and member lists. An email address can always be invited.
    func searchPeople(_ query: String) async throws -> [Person] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let known = people.values.filter { person in
            person.id != selfID && person.name != "Unknown"
                && (query.isEmpty || person.name.localizedCaseInsensitiveContains(query) || person.email?.localizedCaseInsensitiveContains(query) == true)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let isEmail = query.wholeMatch(of: /[^@\s]+@[^@\s]+\.[^@\s]+/) != nil
        guard isEmail, !known.contains(where: { $0.email?.caseInsensitiveCompare(query) == .orderedSame }) else { return known }
        return known + [Person.invite(email: query)]
    }
    /// As web Chat does it: one person through `create_dm_extended`, two or more through `create_group` (a group DM);
    /// both return the conversation these people already share, or create it. People known only by email are invited by email.
    func directMessage(with ids: [PersonID]) async throws -> Conversation {
        let others = ids.filter { $0 != selfID }
        guard !others.isEmpty else { throw DynamiteError.badID }
        let invitees = others.map { id in
            Dynamite_InviteeInfo.with {
                if let email = Person.invitedEmail(id) { $0.email = email; $0.invitationMode = 2 }   // EMAIL_ONLY
                else {
                    $0.userID.id = id; $0.invitationMode = 1   // GAIA_ID
                    if let email = people[id]?.email { $0.email = email }
                }
            }
        }
        let group: Dynamite_GroupId?
        if others.count == 1 {
            let response: Dynamite_CreateDmResponse = try await rpc("create_dm_extended", Dynamite_CreateDmRequest.with { r in
                r.requestHeader = DynamiteClient.header
                r.members = invitees
                r.retentionSettings.state = 1   // PERMANENT: history on
                r.flag8 = false
                r.spaceOrigin = 12   // SUGGESTED_CONTACT, as web Chat sends it
            })
            group = response.hasDm ? response.dm.groupID : nil
        } else {
            let response: Dynamite_CreateGroupResponse = try await rpc("create_group", Dynamite_CreateGroupRequest.with { r in
                r.requestHeader = DynamiteClient.header
                r.space.name = ""
                r.space.invitees = invitees.map { invitee in .with { $0.invitee = invitee; $0.field4 = 1; $0.field5 = 1 } }
                r.space.options.values = [0]
                r.space.avatarInfo = .init()
                r.space.groupType = 4   // FLAT_ROOM: a group DM
                r.space.field15 = false; r.space.field17 = false
                r.localID = DynamiteID.messageID(for: UUID().uuidString)
                r.shouldFindExistingSpace = true
                r.spaceOrigin = 9   // HUMAN, as web Chat sends it
            })
            group = response.hasGroup ? response.group.groupID : nil
        }
        guard let group, let id = DynamiteID.conversation(group) else { throw AuthFailure.malformedProto }
        await resolve(others.filter { Person.invitedEmail($0) == nil })
        // The sidebar item arrives with the server's pushed change; until then, what we know.
        let members = others.map { id in Person.invitedEmail(id).map(Person.invite(email:)) ?? people[id] ?? Person(id: id, name: "Unknown") }
        let kind: ConversationKind = members.count == 1 ? .direct : .group
        return Conversation(id: id, name: members.map(\.name).sorted().joined(separator: ", "), kind: kind,
                            members: [people[selfID] ?? Person(id: selfID, name: "Me")] + members,
                            avatarURL: kind == .direct ? members.first?.avatarURL : nil)
    }
    /// `search_space_directory` as Google Chat's space browser sends it: one page of 20.
    func browseSpaces(_ query: String) async throws -> [SpaceListing] {
        let response: Dynamite_SearchSpaceDirectoryResponse = try await rpc("search_space_directory", Dynamite_SearchSpaceDirectoryRequest.with { r in
            r.requestHeader = DynamiteClient.header
            r.pageSize = 20
            r.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            r.flag9 = false
        })
        return response.spaces.compactMap(DynamiteMapper.space)
    }
    /// `create_membership` with me as a JOINED member, as Google Chat joins from the space browser.
    func shared(_ category: SharedCategory, in conversation: ConversationID, after: SharedContent.Item?) async throws -> SharedPage {
        let pageSize: Int32 = 20
        let request = try Dynamite_ListAttachmentsRequest.with { r in
            r.requestHeader = DynamiteClient.header
            r.groupID = try DynamiteID.group(conversation)
            // Sent in their legacy numbers, as Google Chat's clients do.
            let wanted: Dynamite_AttachmentCategory = switch category { case .media: .mediaLegacy; case .files: .fileLegacy; case .links: .link }
            r.categories = [wanted]
            if category == .media { r.filter.mediaTypes = [1, 2] }   // images and videos
            r.filter.includeInlineReplies = true
            r.filter.field6 = true
            r.direction = 1   // older than the anchor
            r.pageSize = pageSize
            if let anchor = after?.messageID { r.anchor = try DynamiteID.protoMessageID(anchor); r.includeAnchor = false } else { r.includeAnchor = true }
        }
        let response: Dynamite_ListAttachmentsResponse = try await rpc("list_attachments", request)
        let items = response.results.flatMap(\.items)
        await resolve(items.map(\.creator.id))
        let shared = items.compactMap { item -> SharedContent.Item? in
            guard let attachment = DynamiteMapper.sharedAttachment(item.annotation) else { return nil }
            let topic = item.messageID.parentID.topicID.topicID, message = item.messageID.messageID
            return SharedContent.Item(attachment: attachment, date: DynamiteMapper.date(item.createTime),
                                      sender: people[item.creator.id]?.name ?? "",
                                      messageID: topic.isEmpty || message.isEmpty ? nil : DynamiteID.message(conversation, topic: topic, message: message))
        }
        return SharedPage(items: shared, hasMore: items.count >= pageSize && shared.last?.messageID != nil)
    }
    func join(_ space: SpaceListing) async throws -> Conversation {
        let response: Dynamite_CreateMembershipResponse = try await rpc("create_membership", try Dynamite_CreateMembershipRequest.with { r in
            r.requestHeader = DynamiteClient.header
            r.memberIds = [.with { $0.userID.id = selfID }]
            r.membershipState = .memberJoined
            r.groupID = try DynamiteID.group(space.id)
        })
        if response.results.first?.hasFailureReason == true { throw DynamiteError.joinRefused }
        return Conversation(id: space.id, name: space.name, kind: .space, members: [], emoji: space.emoji, avatarURL: space.avatarURL)
    }

    /// Everyone the messages name, then (in a call of their own, as bots) the apps that posted for someone.
    private func resolve(messages: [Dynamite_Message]) async {
        await resolve(messages.flatMap(DynamiteMapper.userIDs))
        await resolve(messages.flatMap { DynamiteMapper.appIDs($0) + DynamiteMapper.cardAppIDs($0) }, bots: true)
    }
    /// Google names someone with a placeholder until they accept a DM: the first live message from each sender re-reads
    /// their profile, and a changed name or photo reloads the conversations that show it.
    private func refreshSender(_ id: String) async {
        guard id != selfID, let before = people[id], refreshedSenders.insert(id).inserted else { return }
        people[id] = nil
        await resolve([id])
        guard let after = people[id] else { people[id] = before; return }
        if after.name != before.name || after.avatarURL != before.avatarURL { continuation.yield(.resync) }
    }
    /// Best effort: a failed lookup leaves names as "Unknown" rather than failing the caller.
    // ponytail: one get_members call per batch, no chunking; chunk if large accounts hit a server cap.
    private func resolve(_ ids: some Sequence<String>, bots: Bool = false) async {
        let missing = Set(ids).subtracting(people.keys).filter { !$0.isEmpty && !unresolvable.contains("\(bots)/\($0)") }
        guard !missing.isEmpty else { return }
        let request = Dynamite_GetMembersRequest.with { r in
            r.requestHeader = DynamiteClient.header
            r.membershipIds = missing.sorted().map { id in .with { $0.memberID.userID.id = id; if bots { $0.memberID.userID.type = .bot } } }
        }
        do {
            let response: Dynamite_GetMembersResponse = try await rpc("get_members", request)
            for profile in response.memberProfiles where !profile.member.user.userID.id.isEmpty {
                people[profile.member.user.userID.id] = DynamiteMapper.person(profile.member.user)
            }
            unresolvable.formUnion(missing.subtracting(people.keys).map { "\(bots)/\($0)" })
        } catch {
            log.error("get_members failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }
}
