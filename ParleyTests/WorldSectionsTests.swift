import Foundation
import SwiftProtobuf
import Testing
@testable import Parley

/// The sidebar's paginated_world request: several sections, each paged by its own token.
extension AuthTests {
    private static let invited = Dynamite_WorldFilter.with { $0.membershipState = .memberInvited; $0.inviteCategory = .regularInvite; $0.groupType = .dm }
    private static func world(_ exchange: StubExchange) throws -> [Dynamite_PaginatedWorldRequest] {
        try exchange.requests.filter { $0.url?.path == "/api/paginated_world" }.map { try .init(serializedBytes: Self.body($0)) }
    }
    private static func dm(_ id: String, _ other: String, sort: Int64) -> Dynamite_WorldItemLite {
        .with { $0.groupID.dmID.dmID = id; $0.sortTimestamp = sort; $0.dmMembers.members = [.with { $0.id = "me" }, .with { $0.id = other }] }
    }
    private static func connectedForWorld(_ replies: [StubExchange.Reply]) async throws -> (DynamiteBackend, StubExchange) {
        let me = try proto(Dynamite_GetMembersResponse.with { $0.memberProfiles = [.with { $0.member.user.userID.id = "me"; $0.member.user.name = "Dave" }] })
        let (auth, exchange) = try signedIn([try proto(Dynamite_GetSelfUserStatusResponse.with { $0.userStatus.userID.id = "me" }), me] + replies)
        let backend = DynamiteBackend(authorizer: auth, realtime: false)
        _ = try await backend.connect()
        return (backend, exchange)
    }

    /// Raw bytes: the unfiltered section {page_size(1)=200}, then invited DMs
    /// {page_size(1)=120, world_filter(4){membership_state(3)=INVITED, invite_category(4)=REGULAR, group_type(6)=DM}}.
    @Test func worldAsksForJoinedAndInvitedSections() async throws {
        let (backend, exchange) = try await Self.connectedForWorld([try Self.proto(Dynamite_PaginatedWorldResponse())])
        _ = try await backend.conversations()
        let body = Self.body(try #require(exchange.requests.last { $0.url?.path == "/api/paginated_world" }))
        let sections = Data([0x12, 0x03, 0x08, 0xC8, 0x01, 0x12, 0x0A, 0x08, 0x78, 0x22, 0x06, 0x18, 0x01, 0x20, 0x01, 0x30, 0x01])
        #expect(body.range(of: sections) != nil)
    }

    @Test func eachSectionPagesWithItsOwnFilterAndToken() async throws {
        let first = Dynamite_PaginatedWorldResponse.with {
            $0.worldSectionResponses = [
                .with { $0.worldFilter = Self.invited; $0.moreItems = true; $0.paginationToken = "i1"; $0.worldItems = [Self.dm("w", "u3", sort: 5)] },
                .with { $0.moreItems = true; $0.paginationToken = "a1" }
            ]
            $0.worldItems = [Self.dm("a", "u1", sort: 1)]
        }
        let second = Dynamite_PaginatedWorldResponse.with {
            $0.worldSectionResponses = [.with { $0.worldFilter = Self.invited }, .with { $0.worldItems = [Self.dm("b", "u2", sort: 9), Self.dm("a", "u1", sort: 1)] }]
        }
        let names = try Self.proto(Dynamite_GetMembersResponse.with {
            $0.memberProfiles = [("u1", "Maria"), ("u2", "Alex"), ("u3", "Sam")].map { id, name in .with { $0.member.user.userID.id = id; $0.member.user.name = name } }
        })
        let (backend, exchange) = try await Self.connectedForWorld([try Self.proto(first), try Self.proto(second), names])
        let rooms = try await backend.conversations()
        #expect(rooms.map(\.id) == ["dm/b", "dm/w", "dm/a"])
        #expect(rooms.map(\.name) == ["Alex", "Sam", "Maria"])
        let requests = try Self.world(exchange)
        #expect(requests.count == 2)
        #expect(requests[0].worldSectionRequests.map(\.paginationToken) == ["", "", "", "", "", "", ""])   // with Home's five
        let paged = requests[1].worldSectionRequests
        #expect(paged.map(\.paginationToken) == ["a1", "i1"])
        #expect(paged.map(\.hasWorldFilter) == [false, true] && paged[1].worldFilter == Self.invited)
        #expect(paged.map(\.pageSize) == [200, 120])
    }
}
