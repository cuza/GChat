import AppKit
import Foundation
import SwiftProtobuf
import Testing
@testable import Parley

/// Finding people, opening DMs and joining spaces through the backend, network-stubbed.
extension AuthTests {
    private static func sent<R: SwiftProtobuf.Message>(_ exchange: StubExchange, _ path: String) throws -> [R] {
        try exchange.requests.filter { $0.url?.path == "/api/\(path)" }.map { try R(serializedBytes: Self.body($0)) }
    }
    private static func rpcs(_ exchange: StubExchange) -> [String] {
        exchange.requests.compactMap { $0.url?.path }.filter { $0.hasPrefix("/api/") }.map { String($0.dropFirst(5)) }
    }

    @Test func peopleSearchMatchesKnownPeopleWithoutAsking() async throws {
        let (backend, exchange) = try await Self.connected()
        let before = Self.rpcs(exchange)
        #expect(try await backend.searchPeople("mar").map(\.id) == ["u1"])
        #expect(try await backend.searchPeople("dave").isEmpty)   // never me
        #expect(try await backend.searchPeople("").map(\.id) == ["u1"])
        #expect(try await backend.searchPeople(" ana@example.com ") == [Person.invite(email: "ana@example.com")])
        #expect(Self.rpcs(exchange) == before)
    }
    @Test func membersKeepTheirEmailForSearch() async throws {
        let page = Dynamite_ListMembersResponse.with {
            $0.members = [.with { $0.user.userID.id = "u2"; $0.user.name = "Ana Lima"; $0.user.email = "ana@example.com" }]
        }
        let (backend, _) = try await Self.connected([try Self.proto(page)])
        _ = try await backend.members(of: "space/s")
        let found = try await backend.searchPeople("ana@example.com")
        #expect(found.map(\.id) == ["u2"] && found.first?.email == "ana@example.com")
    }
    /// As web Chat sends it (captured live): `create_dm_extended` finds the existing DM or creates one, with each member's
    /// user id, email when known and invitation mode 1, retention PERMANENT, field 8 = 0 and field 9 = 12.
    @Test func directMessageAsksCreateDMExtendedWhichAlsoFindsTheExistingOne() async throws {
        let existing = Dynamite_CreateDmResponse.with { $0.dm.groupID.dmID.dmID = "abc" }
        let (backend, exchange) = try await Self.connected([try Self.proto(existing)])
        let room = try await backend.directMessage(with: ["u1"])
        #expect(room.id == "dm/abc" && room.kind == .direct && room.name == "Maria")
        #expect(room.members.map(\.id) == ["me", "u1"])
        #expect(Self.rpcs(exchange).filter { $0.hasPrefix("create_dm") || $0.hasPrefix("find_dm") } == ["create_dm_extended"])
        let request = try #require((try Self.sent(exchange, "create_dm_extended") as [Dynamite_CreateDmRequest]).first)
        #expect(request.members.map(\.userID.id) == ["u1"] && request.members.allSatisfy { $0.invitationMode == 1 })
        #expect(request.retentionSettings.state == 1 && request.hasFlag8 && !request.flag8 && request.spaceOrigin == 12 && request.hasRequestHeader)
    }
    /// As web Chat starts a chat with two people (captured live): `create_group` with an unnamed FLAT_ROOM (type 4), each
    /// invitee wrapped with fields 4 and 5 = 1, options [0], an empty avatar, should_find_existing true and origin 9.
    /// `create_dm_extended` refuses more than one person with HTTP 400.
    @Test func directMessageWithSeveralPeopleCreatesAGroupDM() async throws {
        let created = Dynamite_CreateGroupResponse.with { $0.group.groupID.spaceID.spaceID = "AAQnew" }
        let (backend, exchange) = try await Self.connected([try Self.proto(created)])
        let room = try await backend.directMessage(with: ["u1", "u9"])
        #expect(room.id == "space/AAQnew" && room.kind == .group)
        #expect(Self.rpcs(exchange).filter { $0.hasPrefix("create_") } == ["create_group"])
        let request = try #require((try Self.sent(exchange, "create_group") as [Dynamite_CreateGroupRequest]).first)
        #expect(request.space.invitees.map(\.invitee.userID.id) == ["u1", "u9"])
        #expect(request.space.invitees.allSatisfy { $0.invitee.invitationMode == 1 && $0.field4 == 1 && $0.field5 == 1 })
        #expect(request.space.hasName && request.space.name.isEmpty && request.space.groupType == 4 && request.space.options.values == [0])
        #expect(request.space.hasAvatarInfo && request.space.hasField15 && request.space.hasField17)
        #expect(request.shouldFindExistingSpace && request.spaceOrigin == 9 && request.localID.count == 11 && request.hasRequestHeader)
    }
    @Test func anEmailInviteSkipsTheLookupAndInvitesByEmail() async throws {
        let created = Dynamite_CreateDmResponse.with { $0.dm.groupID.dmID.dmID = "new" }
        let (backend, exchange) = try await Self.connected([try Self.proto(created)])
        let room = try await backend.directMessage(with: [Person.invite(email: "ana@example.com").id])
        #expect(room.id == "dm/new" && room.kind == .direct && room.name == "ana@example.com")
        #expect(Self.rpcs(exchange).filter { $0.hasPrefix("find_dm") }.isEmpty)
        let member = try #require((try Self.sent(exchange, "create_dm_extended") as [Dynamite_CreateDmRequest]).first?.members.first)
        #expect(member.email == "ana@example.com" && member.invitationMode == 2 && !member.hasUserID)
    }
    @Test func browseSpacesSendsTheQueryAndMapsListings() async throws {
        let response = Dynamite_SearchSpaceDirectoryResponse.with {
            $0.spaces = [
                .with {
                    $0.groupID.spaceID.spaceID = "s1"; $0.name = "Design"; $0.avatarInfo.emoji.unicode = "🎨"
                    $0.memberCounts.counts = [.with { $0.count = 12; $0.memberType = 1; $0.membershipState = .memberJoined },
                                              .with { $0.count = 3; $0.memberType = 2; $0.membershipState = .memberJoined },
                                              .with { $0.count = 4; $0.memberType = 1; $0.membershipState = .memberInvited }]
                },
                .with { $0.groupID.spaceID.spaceID = "s2"; $0.name = "Mine"; $0.membershipState = .memberJoined; $0.avatarURL = "//lh3.example.com/a" },
                .with { $0.name = "No id" }
            ]
        }
        let (backend, exchange) = try await Self.connected([try Self.proto(response)])
        let spaces = try await backend.browseSpaces("des")
        #expect(spaces == [SpaceListing(id: "space/s1", name: "Design", emoji: "🎨", memberCount: 12),
                           SpaceListing(id: "space/s2", name: "Mine", avatarURL: URL(string: "https://lh3.example.com/a"), joined: true)])
        let request = try #require((try Self.sent(exchange, "search_space_directory") as [Dynamite_SearchSpaceDirectoryRequest]).first)
        #expect(request.query == "des" && request.pageSize == 20 && request.hasFlag9 && !request.flag9 && request.hasRequestHeader)
        #expect(!request.hasContinuationToken)
    }
    @Test func joinAddsMeAsAJoinedMember() async throws {
        let (backend, exchange) = try await Self.connected([try Self.proto(Dynamite_CreateMembershipResponse.with { $0.results = [.init()] })])
        let room = try await backend.join(SpaceListing(id: "space/s1", name: "Design", emoji: "🎨"))
        #expect(room == Conversation(id: "space/s1", name: "Design", kind: .space, members: [], emoji: "🎨"))
        let request = try #require((try Self.sent(exchange, "create_membership") as [Dynamite_CreateMembershipRequest]).first)
        #expect(request.memberIds.map(\.userID.id) == ["me"] && request.membershipState == .memberJoined)
        #expect(request.groupID.spaceID.spaceID == "s1" && request.hasRequestHeader)
    }
    @Test func aRefusedJoinThrows() async throws {
        let refused = Dynamite_CreateMembershipResponse.with { $0.results = [.with { $0.failureReason = 3 }] }
        let (backend, _) = try await Self.connected([try Self.proto(refused)])
        await #expect(throws: DynamiteError.joinRefused) { _ = try await backend.join(SpaceListing(id: "space/s1", name: "Design")) }
    }
}

@MainActor struct NewConversationStoreTests {
    private func started() async -> (ChatStore, FakeBackend) {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        return (store, fake)
    }
    @Test func messagingSomeoneWithADMOpensItWithoutCreating() async throws {
        let (store, fake) = await started()
        let maria = store.conversations.first { $0.id == "maria" }!.members[1]
        try await store.message([maria])
        #expect(store.selectedID == "maria")
        #expect(await fake.directMessageRequests.isEmpty)
    }
    @Test func messagingSomeoneNewCreatesSelectsAndListsTheDM() async throws {
        let (store, fake) = await started()
        let people = try await store.searchPeople("priya")
        #expect(people.map(\.name) == ["Priya Patel"])
        try await store.message(people)
        #expect(await fake.directMessageRequests == [["priya"]])
        let room = store.conversations.first { $0.id == store.selectedID }
        #expect(room?.kind == .direct && room?.name == "Priya Patel" && store.conversations.first?.id == room?.id)
    }
    @Test func severalPeopleMakeAGroupDMAndAnExistingOneIsReused() async throws {
        let (store, fake) = await started()
        let launch = store.conversations.first { $0.id == "launch" }!
        try await store.message(launch.members.filter { $0.id != store.me.id })
        #expect(store.selectedID == "launch")
        #expect(await fake.directMessageRequests.isEmpty)
        let priya = try await store.searchPeople("priya")
        try await store.message(priya + [launch.members[1]])
        #expect(store.selected?.kind == .group)
        #expect(await fake.directMessageRequests.count == 1)
    }
    @Test func joiningASpaceListsAndSelectsIt() async throws {
        let (store, fake) = await started()
        let spaces = try await store.browseSpaces("photo")
        #expect(spaces.map(\.name) == ["Photography"])
        try await store.join(spaces[0])
        #expect(store.selected?.name == "Photography" && store.selected?.kind == .space)
        #expect(await fake.joined == [spaces[0].id])
        try await store.join(spaces[0])   // already in the sidebar: just opens it
        #expect(await fake.joined.count == 1)
    }
    @Test func failuresReachTheCallerNotTheStoreAlert() async {
        let (store, fake) = await started()
        await fake.simulateDirectoryFailure()
        await #expect(throws: URLError.self) { _ = try await store.browseSpaces("x") }
        #expect(store.error == nil)
    }
}

@MainActor struct PaletteResultsTests {
    let me = Person(id: "me", name: "Dave")
    let maria = Person(id: "maria", name: "Maria Chen")
    let priya = Person(id: "priya", name: "Priya Patel", email: "priya@example.com")
    var rooms: [Conversation] {
        [Conversation(id: "dm1", name: "Maria Chen", kind: .direct, members: [me, maria]),
         Conversation(id: "design", name: "Design studio", kind: .space, members: [me, maria])]
    }
    @Test func conversationsFirstThenNewPeopleThenSpacesNotJoined() {
        let results = PaletteResults(query: "i", conversations: rooms, people: [maria, priya],
                                     spaces: [SpaceListing(id: "design", name: "Design studio"), SpaceListing(id: "s9", name: "Digital")], picked: [])
        #expect(results.conversations.map(\.id) == ["dm1", "design"])
        #expect(results.people == [priya])   // Maria's DM is already listed above
        #expect(results.spaces.map(\.id) == ["s9"])
        #expect(results.items.map(\.id) == ["c:dm1", "c:design", "p:priya", "s:s9"])
    }
    @Test func pickedPeopleLeaveTheResultsAndAnEmptyQueryListsEverything() {
        let results = PaletteResults(query: "", conversations: rooms, people: [maria, priya], spaces: [], picked: [priya])
        #expect(results.conversations.count == 2 && results.people.isEmpty)
    }
    @Test func peopleMatchOnEmailToo() {
        let results = PaletteResults(query: "priya@", conversations: rooms, people: [priya], spaces: [], picked: [])
        #expect(results.conversations.isEmpty && results.people == [priya])
    }
}

@MainActor struct MessagePersonTests {
    private func row(from sender: Person, kind: ConversationKind, offered: @escaping (Person) -> Void) -> MessageRowView {
        let view = MessageRowView()
        var actions = MessageRowActions()
        actions.message = offered
        view.configure(RowLayoutTests.row("hi", sender: sender), own: false, kind: kind, meID: "me", actions: actions)
        return view
    }
    @Test func theSendersMenuMessagesThem() throws {
        var picked: [Person] = []
        let alex = Person(id: "alex", name: "Alex Rivera", email: "alex@example.com")
        let menu = try #require(row(from: alex, kind: .space) { picked.append($0) }.personMenu())
        let item = try #require(menu.items.first { $0.title == "Message Alex Rivera" })
        menu.performActionForItem(at: menu.index(of: item))
        #expect(picked == [alex])
    }
    @Test func notOfferedForMeOrInAOneToOne() {
        #expect(row(from: Person(id: "me", name: "Dave"), kind: .group) { _ in }.personMenu() == nil)
        #expect(row(from: Person(id: "alex", name: "Alex"), kind: .direct) { _ in }.personMenu() == nil)
    }
}
