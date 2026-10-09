import Foundation

/// Keyboard navigation over the sidebar (⌘1…9, ⌥↑/⌥↓ next unread).
extension Conversation {
    /// The sidebar's sections, as web Chat: Ask Gemini, pinned DMs and spaces together, direct messages and groups, spaces,
    /// then DMs with apps; each in server order.
    static func sidebarSections(_ rooms: [Conversation]) -> [(title: String, rooms: [Conversation])] {
        let rest = rooms.filter { $0.app != .gemini }
        return [("Shortcuts", rooms.filter { $0.app == .gemini }), ("Pinned", rest.filter(\.pinned)),
                ("Direct messages", rest.filter { !$0.pinned && $0.kind != .space && $0.app == nil }),
                ("Spaces", rest.filter { !$0.pinned && $0.kind == .space }), ("Apps", rest.filter { !$0.pinned && $0.app != nil })]
    }
    /// The sidebar's order, top to bottom.
    static func sidebarOrder(_ rooms: [Conversation]) -> [Conversation] { sidebarSections(rooms).flatMap(\.rooms) }
    /// ⌘`number` (1-based) opens the conversation at that sidebar position.
    static func atShortcut(_ number: Int, in rooms: [Conversation]) -> Conversation? {
        let order = sidebarOrder(rooms)
        return order.indices.contains(number - 1) ? order[number - 1] : nil
    }
    /// The next (or previous) conversation with unread messages after `current`, wrapping around the sidebar.
    static func nextUnread(after current: ConversationID?, in rooms: [Conversation], forward: Bool) -> Conversation? {
        let order = sidebarOrder(rooms)
        guard !order.isEmpty else { return nil }
        let start = current.flatMap { id in order.firstIndex { $0.id == id } } ?? (forward ? order.count - 1 : 0)
        for step in 1...order.count {
            let index = (start + (forward ? step : -step) % order.count + order.count) % order.count
            if order[index].unread > 0 && order[index].id != current { return order[index] }
        }
        return nil
    }
}
