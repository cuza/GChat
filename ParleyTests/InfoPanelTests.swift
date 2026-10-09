import AppKit
import Testing
@testable import Parley

struct SpaceDescriptionTests {
    /// A space item as paginated_world sends it: group_id(1), room_name(5), group_lite(7) { space_details(8) { description(1), guidelines(2) } }.
    @Test func aSpacesDescriptionComesFromGroupLiteSpaceDetails() throws {
        func field(_ number: UInt8, _ body: [UInt8]) -> [UInt8] { [number << 3 | 2, UInt8(body.count)] + body }
        let details = field(1, Array("Ops: legal".utf8)) + field(2, Array("Be kind".utf8))
        let bytes = field(1, field(1, field(1, Array("s".utf8)))) + field(5, Array("Business".utf8)) + field(7, field(8, details))
        let item = try Dynamite_WorldItemLite(serializedBytes: bytes)
        let room = try #require(DynamiteMapper.conversation(item, selfID: "me", people: [:]))
        #expect(room.name == "Business" && room.description == "Ops: legal")
    }
    @Test func noDescriptionIsNil() throws {
        let item = Dynamite_WorldItemLite.with { $0.groupID.spaceID.spaceID = "s"; $0.roomName = "Plain" }
        #expect(try #require(DynamiteMapper.conversation(item, selfID: "me", people: [:])).description == nil)
    }
    @Test func launchCachesWithoutADescriptionStillDecode() throws {
        let old = #"{"id":"s","name":"A","kind":"space","members":[],"unread":0,"pinned":false,"muted":false}"#
        #expect(try JSONDecoder().decode(Conversation.self, from: Data(old.utf8)).description == nil)
    }
}

struct SharedContentTests {
    private let maria = Person(id: "u1", name: "Maria")
    private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
    @Test func mediaFilesAndLinksComeNewestFirstWithoutRepeats() throws {
        let photo = Attachment(name: "a.png", contentType: "image/png", kind: .image, url: URL(string: "https://x/a.png"))
        let clip = Attachment(name: "c.mp4", contentType: "video/mp4", kind: .video, url: URL(string: "https://x/c.mp4"))
        let file = Attachment(name: "f.pdf", contentType: "application/pdf", kind: .file, url: URL(string: "https://x/f.pdf"))
        let page = URL(string: "https://example.com/a")!
        let preview = Attachment(name: "Example A", kind: .link, url: page, domain: "example.com")
        let old = Message(id: "m1", conversationID: "c", sender: maria, text: "see example", createdAt: at(1), attachments: [photo, clip],
                          formatting: [TextStyleRange(style: .link(page), start: 4, length: 7)])
        let new = Message(id: "m2", conversationID: "c", sender: maria, text: "again https://other.org/b and me@x.com", createdAt: at(2),
                          attachments: [file, photo, preview])
        let pending = Message(id: "m3", conversationID: "c", sender: maria, text: "https://pending.org", createdAt: at(3), delivery: .pending)
        let shared = SharedContent([old, pending, new])
        #expect(shared.media.map(\.attachment) == [photo, clip])
        #expect(shared.media.map(\.date) == [at(2), at(1)])
        #expect(shared.files.map(\.attachment) == [file])
        #expect(shared.links.map(\.attachment.url) == [page, URL(string: "https://other.org/b")])
        #expect(shared.links.first?.attachment.name == "Example A")   // the preview's title, not the bare link
        #expect(shared.links.last?.sender == "Maria")
    }
    @Test func nothingSharedIsEmpty() {
        let shared = SharedContent([Message(id: "m", conversationID: "c", sender: maria, text: "hi")])
        #expect(shared.media.isEmpty && shared.files.isEmpty && shared.links.isEmpty)
    }
}

@MainActor struct InfoPanelStateTests {
    @Test func theInfoPanelAndAThreadShareTheInspector() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        await store.select("design")
        #expect(!store.info)
        store.toggleInfo()
        #expect(store.info)
        let head = try #require(store.timeline("design").first { $0.id == "d4" })
        await store.openThread(head)
        #expect(!store.info && store.threadID == "d4")
        store.toggleInfo()
        #expect(store.info && store.threadID == nil)
        store.toggleInfo()
        #expect(!store.info)
    }
    @Test func commandIItalicizesInAComposerWithTextAndIsLeftForTheInfoPanelWhenEmpty() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 50), styleMask: [.titled], backing: .buffered, defer: true)
        let composer = ComposerTextView(usingTextLayoutManager: false)
        window.contentView = composer
        window.makeFirstResponder(composer)
        let commandI = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                                                     context: nil, characters: "i", charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34))
        #expect(!composer.performKeyEquivalent(with: commandI))
        composer.string = "hello"
        #expect(composer.performKeyEquivalent(with: commandI))
    }
    @Test func membersComeFromTheBackendOnceAndFallBackToTheConversations() async {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        let room = store.conversations.first { $0.id == "launch" }!
        #expect(store.roster(room).map(\.id) == ["me", "maria", "alex"])
        await store.loadMembers("launch")
        await store.loadMembers("launch")
        #expect(await fake.memberRequests == ["launch"])
        #expect(store.roster(room).map(\.id) == ["me", "maria", "alex"])
    }
}
