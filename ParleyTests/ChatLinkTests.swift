import Foundation
import Testing
@testable import Parley

struct ChatLinkTests {
    @Test(arguments: [
        ("https://chat.google.com/room/AAAAspace01/topic000001/topic000001?cls=10", ChatLink(conversations: ["space/AAAAspace01"], topic: "topic000001", message: "topic000001")),
        ("https://chat.google.com/room/AAAAspace01/t1/m2", ChatLink(conversations: ["space/AAAAspace01"], topic: "t1", message: "m2")),
        ("https://chat.google.com/room/AAAAspace01", ChatLink(conversations: ["space/AAAAspace01"])),
        ("https://chat.google.com/dm/dmAAAAAAAA1/t1/t1", ChatLink(conversations: ["dm/dmAAAAAAAA1"], topic: "t1", message: "t1")),
        ("https://chat.google.com/u/0/app/chat/AAAAapp0001", ChatLink(conversations: ["space/AAAAapp0001", "dm/AAAAapp0001"])),
        ("https://mail.google.com/chat/u/0/#chat/space/AAAAapp0001", ChatLink(conversations: ["space/AAAAapp0001"])),
    ])
    func parsesGoogleChatLinks(_ text: String, _ expected: ChatLink) throws {
        #expect(ChatLink(try #require(URL(string: text))) == expected)
    }
    @Test func aCopiedMessageLinkIsGoogleChatsAndOpensTheSameMessage() throws {
        let link = try #require(ChatLink.url(message: "space/AAAAspace01/topic000001/m2"))
        #expect(link.absoluteString == "https://chat.google.com/room/AAAAspace01/topic000001/m2?cls=10")
        #expect(ChatLink(link) == ChatLink(conversations: ["space/AAAAspace01"], topic: "topic000001", message: "m2"))
        #expect(ChatLink.url(message: "dm/abc/t1/t1")?.absoluteString == "https://chat.google.com/dm/abc/t1/t1?cls=10")
        #expect(ChatLink.url(message: "local-draft-id") == nil)
    }
    @Test func otherLinksAreNotChatLinks() throws {
        for text in ["https://example.com/room/x", "https://chat.google.com/", "https://chat.google.com/app/home", "http://chat.google.com/room/x"] {
            #expect(ChatLink(try #require(URL(string: text))) == nil, "\(text)")
        }
    }
    @Test func aSpaceChipOpensTheSpace() throws {
        var proto = Dynamite_Message.with { $0.id.messageID = "m1"; $0.id.parentID.topicID.topicID = "t1"; $0.creator.userID.id = "u1" }
        proto.textBody = "see Lunchroom"
        proto.annotations = [.with { $0.type = .group; $0.startIndex = 4; $0.length = 9; $0.groupMetadata.groupID.spaceID.spaceID = "AAAAspace01" }]
        let message = try #require(DynamiteMapper.message(proto, in: "space/s", selfID: "me", people: [:]))
        #expect(message.formatting == [TextStyleRange(style: .chip("space/AAAAspace01"), start: 4, length: 9)])
        #expect(ChatLink(ChatLink.url("space/AAAAspace01"))?.conversations == ["space/AAAAspace01"])
    }
}
