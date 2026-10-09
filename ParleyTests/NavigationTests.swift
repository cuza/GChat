import Testing
@testable import Parley

struct NavigationTests {
    private let rooms = [
        Conversation(id: "s1", name: "Space", kind: .space, members: [], unread: 2),
        Conversation(id: "d1", name: "Ann", kind: .direct, members: []),
        Conversation(id: "p1", name: "Pinned", kind: .group, members: [], pinned: true),
        Conversation(id: "d2", name: "Bo", kind: .direct, members: [], unread: 1),
    ]
    @Test func sidebarOrderIsPinnedThenDirectThenSpaces() {
        #expect(Conversation.sidebarOrder(rooms).map(\.id) == ["p1", "d1", "d2", "s1"])
    }
    @Test func commandNumbersPickBySidebarPosition() {
        #expect(Conversation.atShortcut(1, in: rooms)?.id == "p1")
        #expect(Conversation.atShortcut(4, in: rooms)?.id == "s1")
        #expect(Conversation.atShortcut(9, in: rooms) == nil)
    }
    @Test func nextUnreadWrapsInSidebarOrder() {
        #expect(Conversation.nextUnread(after: "p1", in: rooms, forward: true)?.id == "d2")
        #expect(Conversation.nextUnread(after: "d2", in: rooms, forward: true)?.id == "s1")
        #expect(Conversation.nextUnread(after: "s1", in: rooms, forward: true)?.id == "d2")   // wraps
        #expect(Conversation.nextUnread(after: "s1", in: rooms, forward: false)?.id == "d2")
        #expect(Conversation.nextUnread(after: nil, in: rooms, forward: true)?.id == "d2")
        #expect(Conversation.nextUnread(after: "p1", in: rooms.map { var r = $0; r.unread = 0; return r }, forward: true) == nil)
    }
}

struct SidebarSectionTests {
    private let rooms = [
        Conversation(id: "s1", name: "Space", kind: .space, members: []),
        Conversation(id: "ps", name: "Pinned space", kind: .space, members: [], pinned: true),
        Conversation(id: "d1", name: "Ann", kind: .direct, members: []),
        Conversation(id: "pd", name: "Pinned DM", kind: .direct, members: [], unread: 3, pinned: true),
    ]
    /// Pinned DMs and spaces share one section, in server order, and don't repeat below.
    @Test func pinnedSectionHoldsDMsAndSpacesOnce() {
        let sections = Conversation.sidebarSections(rooms)
        #expect(sections.map(\.title) == ["Shortcuts", "Pinned", "Direct messages", "Spaces", "Apps"])
        #expect(sections.map { $0.rooms.map(\.id) } == [[], ["ps", "pd"], ["d1"], ["s1"], []])
        #expect(Conversation.sidebarOrder(rooms).map(\.id) == ["ps", "pd", "d1", "s1"])
    }
    /// As web Chat: Ask Gemini on top as a shortcut, app DMs in their own section after spaces; a pinned app stays pinned.
    @Test func appDMsHaveTheirOwnSections() {
        let apps = rooms + [
            Conversation(id: "a1", name: "Google Drive", kind: .direct, members: [], app: .bot),
            Conversation(id: "pa", name: "Pinned app", kind: .direct, members: [], pinned: true, app: .bot),
            Conversation(id: "g", name: "Ask Gemini", kind: .direct, members: [], app: .gemini),
        ]
        let sections = Conversation.sidebarSections(apps)
        #expect(sections.map(\.title) == ["Shortcuts", "Pinned", "Direct messages", "Spaces", "Apps"])
        #expect(sections.map { $0.rooms.map(\.id) } == [["g"], ["ps", "pd", "pa"], ["d1"], ["s1"], ["a1"]])
    }
    @Test func shortcutsAndNextUnreadFollowThePinnedSection() {
        #expect(Conversation.atShortcut(1, in: rooms)?.id == "ps")
        #expect(Conversation.atShortcut(3, in: rooms)?.id == "d1")
        #expect(Conversation.nextUnread(after: "d1", in: rooms, forward: true)?.id == "pd")   // wraps to the pinned DM
    }
}
