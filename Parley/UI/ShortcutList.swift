import SwiftUI

/// Home: conversations by recent activity, a click opens one. Mentions or Starred: messages from every conversation,
/// newest first; a click opens the message where it is.
struct ShortcutList: View {
    @Bindable var store: ChatStore
    let shortcut: Shortcut
    var body: some View {
        let items = store.shortcutMessages(shortcut)
        Group {
            if shortcut == .home {
                let rows = store.homeRows(unreadOnly: store.homeUnreadOnly, threadsOnly: store.homeThreadsOnly)
                VStack(spacing: 0) {
                    HStack(spacing: 12) {   // web's "Unread" switch and "Thread" filter
                        Toggle("Unread", isOn: $store.homeUnreadOnly).toggleStyle(.switch).controlSize(.mini)
                        Toggle(isOn: $store.homeThreadsOnly) { Label("Threads", systemImage: "bubble.left.and.text.bubble.right") }.toggleStyle(.button).controlSize(.small)
                        Spacer()
                    }
                    .font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 6)
                    if rows.isEmpty {
                        ContentUnavailableView(store.homeUnreadOnly || store.homeThreadsOnly ? "Nothing here" : "No recent conversations", systemImage: shortcut.icon,
                                               description: Text(store.homeUnreadOnly || store.homeThreadsOnly ? "No rows match these filters." : "Conversations with new messages show up here."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)   // fills the pane, so the filter bar stays at the top
                    } else {
                        List(rows) { row in
                            if let thread = row.thread {
                                Button { Task { await store.openHomeThread(thread) } } label: { threadRow(row.room, thread) }
                                    .buttonStyle(.plain)
                                    .listRowBackground(store.threadID == thread.id ? Color.accentColor.opacity(0.15) : nil)
                            } else {
                                Button { Task { await store.select(row.room.id) } } label: { homeRow(row.room, row.last) }
                                    .buttonStyle(.plain)
                                    .contextMenu { if row.room.unread > 0 { Button("Mark as read") { Task { await store.markRead(row.room.id) } } } }
                                    .task(id: store.me.id) { await store.loadPreview(row.room.id) }   // again once the account is known
                            }
                        }
                        .accessibilityIdentifier("shortcut-home")
                    }
                }
            } else if !items.isEmpty {
                List(items) { message in
                    Button { Task { await store.showInChat(message) } } label: { row(message) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(message.starred ? "Unstar" : "Star") { Task { await store.setStarred(!message.starred, message) } }
                        }
                        .onAppear { if message.id == items.last?.id { Task { await store.loadShortcut(shortcut, more: true) } } }
                }
                .accessibilityIdentifier("shortcut-\(shortcut.rawValue)")
            } else if store.loading.contains("shortcut/\(shortcut.rawValue)") {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(shortcut == .starred ? "No starred messages" : "No mentions", systemImage: shortcut.icon,
                                       description: Text(shortcut == .starred ? "Star a message to find it here." : "Messages that @mention you show up here."))
            }
        }
        .navigationTitle(shortcut.title)
    }
    /// Name, time and unread count over the newest message, as "You: …" or "Sender: …".
    private func homeRow(_ room: Conversation, _ last: Message?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: room.name, space: room.kind == .space, size: 32, url: room.avatarURL, emoji: room.emoji)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(room.name).font(.system(size: 13, weight: room.unread > 0 ? .semibold : .regular)).lineLimit(1)
                    if room.muted { Image(systemName: "bell.slash").font(.caption2).foregroundStyle(.secondary) }
                    Spacer(minLength: 8)
                    if let time = last?.createdAt ?? room.activity { Text(Self.time(time)).font(.caption).foregroundStyle(.secondary).fixedSize() }
                }
                HStack(spacing: 4) {
                    Group {
                        if let last { line(last) } else { Text(" ") }
                    }
                    .font(.system(size: 13, weight: room.unread > 0 ? .medium : .regular)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    if room.unread > 0 {
                        Text("\(room.unread)").font(.system(size: 11, weight: .semibold, design: .rounded)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.blue, in: Capsule()).foregroundStyle(.white).fixedSize()
                    }
                }
            }
        }
        .padding(.vertical, 4).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
    /// "You: " or "Sender: " before a message's summary.
    private func line(_ message: Message) -> Text {
        Text(message.sender.id == store.me.id ? "You: " : "\(message.sender.name): ").foregroundStyle(.secondary)
            + Text(Self.oneLine(QuotedMessage.summary(text: TextStyleRange.plain(message.text, message.formatting), attachments: message.attachments)))
    }
    /// As web's thread row: the conversation and time, the thread's first message, then "└ newest reply"; bold with a dot when unread.
    private func threadRow(_ room: Conversation, _ thread: HomeThread) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: room.name, space: room.kind == .space, size: 32, url: room.avatarURL, emoji: room.emoji)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill").font(.system(size: 8)).foregroundStyle(.secondary)
                        .padding(2).background(.background, in: Circle()).offset(x: 4, y: 4)
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(room.name).font(.system(size: 13, weight: thread.unread ? .semibold : .regular)).lineLimit(1)
                    Text("· Thread").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
                    Spacer(minLength: 8)
                    Text(Self.time(thread.time)).font(.caption).foregroundStyle(.secondary).fixedSize()
                    if thread.unread { Circle().fill(.blue).frame(width: 8, height: 8).accessibilityLabel("Unread") }
                }
                line(thread.head).font(.system(size: 13)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("└").foregroundStyle(.tertiary)
                    line(thread.latest).font(.system(size: 13, weight: thread.unread ? .medium : .regular)).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
    /// As Google Chat's Home: the time within a day, then "Yesterday", the weekday within a week, the date this year,
    /// and the month and year before that.
    static func time(_ date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if now.timeIntervalSince(date) < 24 * 3600 { return date.formatted(style.hour().minute()) }
        if calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: now)!) {
            return String(localized: "Yesterday", locale: locale)
        }
        if now.timeIntervalSince(date) < 7 * 24 * 3600 { return date.formatted(style.weekday(.abbreviated)) }
        style = calendar.isDate(date, equalTo: now, toGranularity: .year) ? style.month(.abbreviated).day() : style.month(.abbreviated).year()
        return date.formatted(style)
    }
    /// A preview on one paragraph: line breaks and runs of spaces become one space, as Google Chat's Home shows it.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private func row(_ message: Message) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: message.sender.name, size: 32, url: message.sender.avatarURL)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(message.sender.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("· \(store.conversations.first { $0.id == message.conversationID }?.name ?? "Conversation")")
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    if message.starred { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow).accessibilityLabel("Starred") }
                    Text(message.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary).fixedSize()
                }
                Text(QuotedMessage.summary(text: TextStyleRange.plain(message.text, message.formatting), attachments: message.attachments))
                    .font(.system(size: 13)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4).contentShape(Rectangle())
    }
}

/// The Drafts shortcut, as web's: every composer holding a draft, newest first; a click opens the conversation, or the thread
/// in the thread pane, with the draft in its composer.
struct DraftList: View {
    @Bindable var store: ChatStore
    var body: some View {
        let drafts = store.draftList()
        Group {
            if drafts.isEmpty {
                ContentUnavailableView("No drafts", systemImage: Shortcut.drafts.icon, description: Text("Messages you start and don’t send show up here."))
            } else {
                List(drafts, id: \.self) { draft in
                    Button { Task { await store.open(conversation: draft.conversationID, thread: draft.threadID) } } label: { row(draft) }
                        .buttonStyle(.plain)
                }
                .accessibilityIdentifier("shortcut-drafts")
            }
        }
        .navigationTitle(Shortcut.drafts.title)
    }
    private func row(_ draft: ServerDraft) -> some View {
        let room = store.conversations.first { $0.id == draft.conversationID }
        return HStack(alignment: .top, spacing: 10) {
            Avatar(name: room?.name ?? "", space: room?.kind == .space, size: 32, url: room?.avatarURL, emoji: room?.emoji)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(room?.name ?? "Conversation").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if draft.threadID != nil { Text("· Thread").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize() }
                    Spacer(minLength: 8)
                    if draft.updatedAt != .distantPast { Text(ShortcutList.time(draft.updatedAt)).font(.caption).foregroundStyle(.secondary).fixedSize() }
                }
                Text(TextStyleRange.plain(draft.text, draft.formatting)).font(.system(size: 13)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
