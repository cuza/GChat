import Foundation
import Testing
@testable import Parley

@MainActor struct AttachmentSendTests {
    private func started() async throws -> (FakeBackend, ChatStore, ConversationID) {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        return (fake, store, try #require(store.selectedID))
    }
    @Test func filesAndTextGoOutAsOneMessage() async throws {
        let (fake, store, id) = try await started()
        let image = try temporaryImage()
        store.attach([image], conversation: id, thread: nil)
        store.setDraft(" look ", conversation: id, thread: nil)
        await store.send(conversation: id)
        let draft = try #require(await fake.sentDrafts.last)
        #expect(draft.text == "look")
        #expect(draft.uploads.map(\.url) == [image] && draft.uploads.allSatisfy { $0.uploadToken == "fake-shot.png" })
        #expect(store.draftAttachments[store.key(id, nil)] == nil && store.drafts[store.key(id, nil)] == "")
        let sent = try #require(store.messages.last { $0.sender.id == store.me.id })
        #expect(sent.delivery == .sent && sent.attachments.map(\.url) == [image])
    }
    @Test func filesAloneCanBeSentAndRemoved() async throws {
        let (fake, store, id) = try await started()
        let first = try temporaryImage(name: "a.png"), second = try temporaryImage(name: "b.png")
        store.attach([first, second], conversation: id, thread: nil)
        store.detach(try #require(store.draftAttachments[store.key(id, nil)]?.first), conversation: id, thread: nil)
        await store.send(conversation: id)
        let draft = try #require(await fake.sentDrafts.last)
        #expect(draft.uploads.map(\.url) == [second] && draft.text.isEmpty)
    }
    @Test func refusedFilesExplainWhyAndStayOut() async throws {
        let (_, store, id) = try await started()
        let folder = try temporaryImage().deletingLastPathComponent()
        store.attach([folder], conversation: id, thread: nil)
        #expect(store.draftAttachments[store.key(id, nil)] ?? [] == [])
        #expect(store.error?.contains(folder.lastPathComponent) == true)
    }
    @Test func failedUploadEchoesTheLocalImageAndRetries() async throws {
        let (fake, store, id) = try await started()
        let image = try temporaryImage()
        store.attach([image], conversation: id, thread: nil)
        await fake.simulateUploadFailure()
        await store.send(conversation: id)
        let echo = try #require(store.messages.first { $0.delivery == .failed })
        #expect(echo.attachments.map(\.url) == [image] && echo.attachments.first?.uploadToken == nil)
        #expect(await fake.sentDrafts.isEmpty)
        // The echo's preview comes from disk.
        #expect(try await store.attachmentData(try #require(echo.attachments.first), thumbnail: true) == Data(contentsOf: image))
        await store.retry(echo)
        #expect(await fake.uploaded.count == 2)
        #expect(store.messages.last { $0.sender.id == store.me.id }?.delivery == .sent)
    }
    @Test func retryAfterAFailedSendDoesNotUploadAgain() async throws {
        let (fake, store, id) = try await started()
        store.attach([try temporaryImage()], conversation: id, thread: nil)
        await fake.simulateSendFailure()
        await store.send(conversation: id)
        let echo = try #require(store.messages.first { $0.delivery == .failed })
        #expect(echo.attachments.first?.uploadToken == "fake-shot.png")
        await store.retry(echo)
        #expect(await fake.uploaded.count == 1)
        let drafts = await fake.sentDrafts
        #expect(drafts.count == 2 && drafts.last?.localID == echo.id)
    }
    @Test func pendingUploadsAreCounted() async throws {
        let (_, store, id) = try await started()
        let local = try Attachment.localFile(at: try temporaryImage())
        store.apply(.messageUpserted(Message(id: "local-x", conversationID: id, sender: store.me, text: "", delivery: .pending, attachments: [local])))
        #expect(store.uploading(id) == 1)
        var done = local
        done.uploadToken = "t"
        store.apply(.messageUpserted(Message(id: "local-x", conversationID: id, sender: store.me, text: "", delivery: .pending, attachments: [done])))
        #expect(store.uploading(id) == 0)
    }
}
