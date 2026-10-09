import SwiftUI

/// A link to a Google Chat conversation or message, as Google Chat writes them, so Parley can open it in place.
/// `chat.google.com/room/<space>[/<topic>[/<message>]]`, `/dm/<dm>[/…]`, `/app/chat/<id>` (space or DM: both are tried),
/// optionally after `/u/<n>`, and Gmail's `mail.google.com/chat/…#chat/space/<id>` (or `#chat/dm/<id>`).
struct ChatLink: Equatable {
    var conversations: [ConversationID]   // in order of preference; more than one when the link doesn't say which kind
    var topic: String? = nil
    var message: String? = nil

    init?(_ url: URL) {
        guard url.scheme == "https", let host = url.host()?.lowercased() else { return nil }
        var parts: [String]
        switch host {
        case "chat.google.com": parts = url.pathComponents.filter { $0 != "/" }
        case "mail.google.com": parts = (url.fragment ?? "").split(separator: "/").map(String.init)
        default: return nil
        }
        if parts.first == "u", parts.count > 1 { parts.removeFirst(2) }
        if parts.first == "app" || parts.first == "chat" { parts.removeFirst() }
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        switch parts[0] {
        case "room", "space": conversations = ["space/\(parts[1])"]
        case "dm": conversations = ["dm/\(parts[1])"]
        case "chat": conversations = ["space/\(parts[1])", "dm/\(parts[1])"]
        default: return nil
        }
        if parts.count >= 3, !parts[2].isEmpty { topic = parts[2]; message = parts.count >= 4 && !parts[3].isEmpty ? parts[3] : parts[2] }
    }
    init(conversations: [ConversationID], topic: String? = nil, message: String? = nil) {
        self.conversations = conversations; self.topic = topic; self.message = message
    }
    /// The link Google Chat copies for a message (`<conversation>/<topic>/<message>`); nil for an id that isn't one.
    static func url(message id: MessageID) -> URL? {
        let parts = id.split(separator: "/").map(String.init)
        guard parts.count == 4 else { return nil }
        return URL(string: "\(url("\(parts[0])/\(parts[1])").absoluteString)/\(parts[2])/\(parts[3])?cls=10")
    }
    /// The link Google Chat uses for a conversation.
    static func url(_ conversation: ConversationID) -> URL {
        let parts = conversation.split(separator: "/", maxSplits: 1)
        let kind = parts.first == "dm" ? "dm" : "room"
        return URL(string: "https://chat.google.com/\(kind)/\(parts.last ?? "")")!
    }
}

extension ChatLink {
    /// Web's card for a conversation this account can't open (another account's, or one it isn't a member of).
    var restrictedTitle: String { conversations.count == 1 && conversations[0].hasPrefix("space/") ? "Restricted space" : "Restricted conversation" }
    /// Shows that card above `rect` (screen coordinates, taken at the click), as the emoji hover card shows: a panel
    /// placed once, which a row's reused views can't move. The next click, key or scroll closes it.
    @MainActor static func showRestricted(_ link: ChatLink, above rect: NSRect, in window: NSWindow) {
        RestrictedPanel.shared.show(RestrictedCard(title: link.restrictedTitle), above: rect, in: window)
    }
}

@MainActor private final class RestrictedPanel {
    static let shared = RestrictedPanel()
    private var panel: NSPanel?
    private var monitor: Any?
    func show(_ card: RestrictedCard, above rect: NSRect, in window: NSWindow) {
        hide()
        let host = NSHostingView(rootView: card)
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(x: rect.midX - size.width / 2, y: rect.maxY + 6, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.contentView = host
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            self?.hide(); return event
        }
    }
    func hide() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
        panel = nil
    }
}

/// As Google Chat's web card for a space the account can't see: a lock, "Restricted space", and why.
struct RestrictedCard: View {
    let title: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock").font(.title2).foregroundStyle(.secondary)
                .frame(width: 44, height: 44).background(.quaternary, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text("Not in this account: you may not be a member, or it belongs to another Google account.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }
}
