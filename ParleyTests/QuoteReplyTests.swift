import AppKit
import SwiftUI
import Foundation
import Testing
@testable import Parley

struct QuoteReplyMapperTests {
    @Test func messagesKeepTheirLastUpdateTimeForQuoting() throws {
        var proto = AuthTests.message("m1", topic: "t1", at: 10)
        proto.lastUpdateTime = 25
        #expect(DynamiteMapper.message(proto, in: "dm/a", selfID: "me", people: [:])?.lastUpdateMicros == 25)
        proto.lastUpdateTime = 0; proto.lastEditTime = 17   // older servers: the edit, else the create time
        #expect(DynamiteMapper.message(proto, in: "dm/a", selfID: "me", people: [:])?.lastUpdateMicros == 17)
        proto.lastEditTime = 0
        #expect(DynamiteMapper.message(proto, in: "dm/a", selfID: "me", people: [:])?.lastUpdateMicros == 10)
    }
    @Test func quoteTypeQuoteReplyIsOneOnTheWire() throws {
        let ref = try #require(try DynamiteMapper.quotedRef(QuotedMessage(sender: "Maria", text: "hi", id: "dm/a/t1/m1", lastUpdateMicros: 300)))
        #expect(ref.quoteType.rawValue == 1)
        let bytes: [UInt8] = try ref.serializedBytes()
        #expect(bytes.suffix(2) == [0x20, 0x01])                             // field 4, varint 1
        #expect(bytes.contains(0x10) && ref.lastUpdateTime == 300)           // field 2, varint
        #expect(ref.messageID.messageID == "m1" && ref.messageID.parentID.topicID.topicID == "t1"
                && ref.messageID.parentID.topicID.groupID.dmID.dmID == "a")
        #expect(try DynamiteMapper.quotedRef(QuotedMessage(sender: "Maria", text: "hi")) == nil)   // a received snapshot names no message
    }
}

/// Network-stubbed: joins the serialized AuthTests suite (the stub registry is global).
extension AuthTests {
    @Test func quoteRepliesCarryTheQuotedMessageOnCreateTopicAndCreateMessage() async throws {
        let topic = try Self.proto(Dynamite_CreateTopicResponse.with { $0.topic.replies = [Self.message("m9", topic: "m9", at: 5, by: "me")] })
        let reply = try Self.proto(Dynamite_CreateMessageResponse.with { $0.message = Self.message("r9", topic: "m9", at: 6, by: "me") })
        let (backend, exchange) = try await Self.connected([topic, reply])
        let quote = QuotedMessage(sender: "Maria", text: "hello", id: "dm/a/t1/m1", lastUpdateMicros: 1_700_000_000_123_456)
        let sent = try await backend.send(MessageDraft(text: "yes", localID: "local-1", quoting: quote), to: "dm/a", thread: nil)
        _ = try await backend.send(MessageDraft(text: "yes", localID: "local-2", quoting: quote), to: "dm/a", thread: sent.id)
        let topics = try exchange.requests.filter { $0.url?.path == "/api/create_topic" }.map { try Dynamite_CreateTopicRequest(serializedBytes: Self.body($0)) }
        let replies = try exchange.requests.filter { $0.url?.path == "/api/create_message" }.map { try Dynamite_CreateMessageRequest(serializedBytes: Self.body($0)) }
        for info in [try #require(topics.first).messageInfo, try #require(replies.first).messageInfo] {
            #expect(info.hasQuotedMessage)
            #expect(info.quotedMessage.quoteType == .quoteReply)
            #expect(info.quotedMessage.lastUpdateTime == 1_700_000_000_123_456)
            #expect(info.quotedMessage.messageID.messageID == "m1" && info.quotedMessage.messageID.parentID.topicID.topicID == "t1")
            #expect(!info.acceptFormatAnnotations)
        }
    }
    @Test func plainSendsCarryNoQuote() async throws {
        let topic = try Self.proto(Dynamite_CreateTopicResponse.with { $0.topic.replies = [Self.message("m9", topic: "m9", at: 5, by: "me")] })
        let (backend, exchange) = try await Self.connected([topic])
        _ = try await backend.send(MessageDraft(text: "plain", localID: "local-1"), to: "dm/a", thread: nil)
        let request = try Dynamite_CreateTopicRequest(serializedBytes: Self.body(try #require(exchange.requests.last)))
        #expect(!request.messageInfo.hasQuotedMessage)
    }
}

@MainActor struct QuoteReplyStoreTests {
    @Test func quotingShowsInTheEchoIsSentAndThenCleared() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        var quoted = try #require(store.messages.first { $0.id == "d1" })
        quoted.lastUpdateMicros = 42
        store.quote(quoted)
        let scope = store.key("design", nil)
        #expect(store.quoting[scope] == QuotedMessage(sender: "Maria Chen", text: quoted.text, id: "d1", lastUpdateMicros: 42))
        store.setDraft("sure", conversation: "design", thread: nil)
        await fake.simulateSendFailure()   // keeps the local echo in the store
        await store.send(conversation: "design")
        let echo = try #require(store.messages.first { $0.delivery == .failed })
        #expect(echo.quote?.sender == "Maria Chen" && echo.quote?.text == quoted.text)
        let sent = await fake.sentDrafts.last?.quoting
        #expect(sent?.id == "d1" && sent?.lastUpdateMicros == 42)
        #expect(store.quoting[scope] == nil)
        await store.retry(echo)   // a retry quotes the same message
        #expect(await fake.sentDrafts.last?.quoting?.id == "d1")
        #expect(store.messages.contains { $0.text == "sure" && $0.quote?.sender == "Maria Chen" && $0.delivery == .sent })
    }
    @Test func aQuoteWithoutAServerUpdateTimeUsesTheCreateTime() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let quoted = try #require(store.messages.first { $0.id == "d1" })
        store.quote(quoted)
        #expect(store.quoting[store.key("design", nil)]?.lastUpdateMicros == Int64((quoted.createdAt.timeIntervalSince1970 * 1_000_000).rounded()))
    }
    @Test func quotingInAThreadStaysWithThatThread() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        let head = try #require(store.messages.first { $0.id == "d4" })
        await store.openThread(head)
        let reply = try #require(store.messages.first { $0.id == "r1" })
        store.quote(reply)
        #expect(store.quoting[store.key("design", "d4")]?.id == "r1" && store.quoting[store.key("design", nil)] == nil)
        store.setDraft("agreed", conversation: "design", thread: "d4")
        await store.send(conversation: "design", thread: "d4")
        #expect(await fake.sentDrafts.last?.quoting?.id == "r1")
        #expect(store.timeline("design", thread: "d4").last?.quote?.sender == "Maria Chen")
        #expect(store.quoting.isEmpty)
    }
    @Test func pendingAndServiceMessagesCannotBeQuotedAndEditingTakesOver() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        var pending = try #require(store.messages.first { $0.id == "d1" }); pending.delivery = .pending
        store.quote(pending)
        var service = try #require(store.messages.first { $0.id == "d1" }); service.isSystem = true
        store.quote(service)
        #expect(store.quoting.isEmpty)
        store.quote(try #require(store.messages.first { $0.id == "d1" }))
        store.edit(try #require(store.messages.first { $0.id == "d3" }))   // editing my message drops the quote
        #expect(store.quoting.isEmpty && store.editingID("design", thread: nil) == "d3")
        store.quote(try #require(store.messages.first { $0.id == "d1" }))   // and quoting ends the edit
        #expect(store.editingID("design", thread: nil) == nil && store.drafts[store.key("design", nil)] == "")
    }
}

/// Seen live: quoting a photo with no text showed an empty quote block. Web Chat names the attachment instead.
@MainActor struct QuotedAttachmentTests {
    @Test func aQuoteOfATextlessMessageNamesItsAttachment() {
        func file(_ kind: Parley.Attachment.Kind, _ type: String, _ name: String = "x") -> Parley.Attachment { Parley.Attachment(name: name, contentType: type, kind: kind) }
        #expect(QuotedMessage.summary(text: "", attachments: [file(.image, "image/png")]) == "Photo")
        #expect(QuotedMessage.summary(text: "", attachments: [file(.image, "image/gif")]) == "GIF")
        #expect(QuotedMessage.summary(text: "", attachments: [file(.video, "video/mp4")]) == "Video")
        #expect(QuotedMessage.summary(text: "", attachments: [file(.file, "application/pdf", "plan.pdf")]) == "plan.pdf")
        #expect(QuotedMessage.summary(text: "hi", attachments: [file(.image, "image/png")]) == "hi")
        #expect(QuotedMessage.summary(text: "", attachments: []) == "")
    }
    @Test func quotingAPhotoFromTheComposerNamesIt() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let id = try #require(store.selectedID)
        let photo = Message(id: "p", conversationID: id, sender: Person(id: "a", name: "A"), text: "",
                            attachments: [Parley.Attachment(name: "image.png", contentType: "image/png", kind: .image)])
        store.quote(photo)
        #expect(store.quoting[store.key(id, nil)]?.text == "Photo")
        #expect(store.quoting[store.key(id, nil)]?.media?.name == "image.png")   // the composer shows its thumbnail, as Telegram does
    }
}

/// Clicking a quote goes to the message it quotes, as Telegram does.
@MainActor struct QuoteJumpTests {
    @Test func aReceivedQuoteKeepsTheQuotedMessagesID() throws {
        let proto = Dynamite_Message.with {
            $0.id.parentID.topicID.topicID = "t1"; $0.id.messageID = "m2"; $0.creator.userID.id = "u1"; $0.textBody = "reply"
            $0.quotedMessageMetadata = .with { $0.messageID.parentID.topicID.topicID = "t0"; $0.messageID.messageID = "m0"; $0.textBody = "orig" }
        }
        let message = try #require(DynamiteMapper.message(proto, in: "dm/a", selfID: "me", people: [:]))
        #expect(message.quote?.id == DynamiteID.message("dm/a", topic: "t0", message: "m0"))
    }
    @Test func showingALoadedQuotedMessageHighlightsIt() async throws {
        let store = ChatStore(backend: FakeBackend(longHistory: 200))
        await store.start()
        await store.select("engineering")
        let loaded = try #require(store.timeline("engineering").first)
        await store.showQuoted(loaded.id, in: "engineering")
        #expect(store.highlightedID == loaded.id)
    }
    @Test func showingAnOlderQuotedMessageLoadsBackToIt() async throws {
        let store = ChatStore(backend: FakeBackend(longHistory: 200))
        await store.start()
        await store.select("engineering")
        #expect(!store.timeline("engineering").contains { $0.id == "e5" })
        await store.showQuoted("e5", in: "engineering")
        #expect(store.timeline("engineering").contains { $0.id == "e5" } && store.highlightedID == "e5")
    }
}

@MainActor
struct ThreadPaneTests {
    /// The thread pane's header draws the first message as the timeline does, held to four lines until clicked.
    @Test func theHeaderIsTheMessagesOwnTextLimitedToFourLines() {
        let long = Array(repeating: "A line of the thread's first message that wraps.", count: 12).joined(separator: " ")
        func height(_ lines: Int) -> CGFloat {
            let host = NSHostingView(rootView: NativeMessageText(text: long, own: false, lines: lines, maxWidth: .infinity).frame(width: 300))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let four = height(4), all = height(0)
        #expect(four > 50 && four < 90)   // four lines of the 13 pt message font
        #expect(all > four * 2)
    }
}

@MainActor
struct WindowMinimumTests {
    /// The window's needs are the sum of the shown areas: the sidebar at its measured width, the timeline's minimum and,
    /// while open, the side pane.
    @Test func theNeededWidthIsTheShownAreas() {
        #expect(ChatView.minWidth(paneOpen: false, sidebar: 0) == ChatView.timelineMinWidth)
        #expect(ChatView.minWidth(paneOpen: true, sidebar: 0) == ChatView.timelineMinWidth + 1 + ChatView.paneWidth)
        #expect(ChatView.minWidth(paneOpen: true, sidebar: 230) == 230 + ChatView.timelineMinWidth + 1 + ChatView.paneWidth)
    }
    /// Opening a pane grows the window only by what it lacks, never past what the shown areas need.
    @Test func openingAPaneGrowsTheWindowOnlyToWhatItNeeds() {
        #expect(ChatView.widthForPane(window: 380, sidebar: 0) == 701)
        #expect(ChatView.widthForPane(window: 760, sidebar: 230) == 931)
        #expect(ChatView.widthForPane(window: 1400, sidebar: 230) == 1400)   // room already: unchanged
    }
    @Test func theSidebarHidesWhenTheWindowNarrowsAndReturnsWhenItWidens() {
        let fits = ChatView.minWidth(paneOpen: true, sidebar: 230)
        func decide(_ width: CGFloat, _ visible: Bool, _ autoHidden: Bool) -> (visible: Bool, autoHidden: Bool) {
            ChatView.sidebar(width: width, paneOpen: true, sidebarWidth: 230, visible: visible, autoHidden: autoHidden)
        }
        #expect(decide(fits - 1, true, false) == (visible: false, autoHidden: true))   // too narrow: we hide it
        #expect(decide(fits, false, true) == (visible: true, autoHidden: false))       // room again: back
        #expect(decide(fits + 400, false, false) == (visible: false, autoHidden: false))   // hidden by the user: stays
    }
}

@MainActor
struct ConversationWindowTests {
    /// A conversation opened in its own window shows just that conversation: no sidebar until asked for.
    @Test func aConversationWindowOpensWithoutTheSidebar() {
        #expect(ChatView.initialColumns(fixedConversation: "space/x") == .detailOnly)
        #expect(ChatView.initialColumns(fixedConversation: nil) == .all)
    }
    /// Every window shares the store, so a pane opening is seen by all of them: each grows only its own window.
    @Test func growingForAPaneTouchesOnlyThatWindow() {
        let mine = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        ChatView.makeRoom(701, in: mine, animate: false)
        #expect(mine.frame.width >= 701)
        #expect(other.frame.width == 380)
    }
    /// Opening a pane there grows the window by the pane alone, not as if a sidebar were beside it.
    @Test func aConversationWindowCountsNoSidebar() {
        #expect(ChatView.shownSidebar(fixedConversation: "space/x", columns: .all, measured: 230) == 0)
        #expect(ChatView.shownSidebar(fixedConversation: nil, columns: .all, measured: 230) == 230)
        #expect(ChatView.shownSidebar(fixedConversation: nil, columns: .detailOnly, measured: 230) == 0)
    }
}
