import AppKit
import Testing
@testable import Parley

/// Each test writes its own named pasteboard, never the general one.
@MainActor struct ComposerPasteTests {
    private func board(_ fill: (NSPasteboard) throws -> Void) rethrows -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("ParleyTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        try fill(pasteboard)
        return pasteboard
    }
    @Test func imageDataBecomesAPendingPNGFile() throws {
        let image = try Data(contentsOf: try temporaryImage(width: 8, height: 6))
        let tiff = try #require(NSImage(data: image)?.tiffRepresentation)
        for (type, data) in [(NSPasteboard.PasteboardType.png, image), (.tiff, tiff)] {
            let pasteboard = board { $0.setData(data, forType: type) }
            let files = try #require(ComposerTextView.files(on: pasteboard))
            #expect(files.count == 1 && files[0].pathExtension == "png")
            let attachment = try Attachment.localFile(at: files[0])
            #expect(attachment.kind == .image && attachment.width == 8 && attachment.height == 6)
        }
    }
    @Test func plainTextStaysText() {
        #expect(ComposerTextView.files(on: board { $0.setString("hello", forType: .string) }) == nil)
        // Rich text from another app may carry a picture of itself; the text wins.
        let both = board { $0.setString("hello", forType: .string); $0.setData(Data([1, 2, 3]), forType: .tiff) }
        #expect(ComposerTextView.files(on: both) == nil)
        #expect(ComposerTextView.files(on: board { _ in }) == nil)
    }
    @Test func copiedFilesArriveAsTheyAre() throws {
        let url = try temporaryImage()
        let pasteboard = board { $0.writeObjects([url as NSURL]) }   // Finder also puts the name as text
        #expect(ComposerTextView.files(on: pasteboard) == [url])
    }
    @Test func composerAcceptsFileDrops() {
        let view = ComposerTextView(usingTextLayoutManager: false)
        #expect(view.acceptableDragTypes.contains(.fileURL) && view.acceptableDragTypes.contains(.png))
        #expect(NSFilePromiseReceiver.readableDraggedTypes.allSatisfy { view.acceptableDragTypes.contains(.init($0)) })
        #expect(view.readablePasteboardTypes == [.string])   // pasted text still comes in plain
    }
    /// The text view enables Paste only for types it reads (plain text), so a copied screenshot left ⌘V disabled.
    @Test func pasteIsEnabledForImagesAndFiles() throws {
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.attach = { _ in }
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let image = try Data(contentsOf: try temporaryImage())
        view.clipboard = board { $0.setData(image, forType: .png) }
        #expect(view.validateMenuItem(paste))
        view.clipboard = board { $0.writeObjects([try! temporaryImage() as NSURL]) }
        #expect(view.validateMenuItem(paste))
        // Nothing to attach: AppKit decides from the system clipboard, which a test does not control.
        #expect(!ComposerTextView.hasFiles(on: board { _ in }) && !ComposerTextView.hasFiles(on: board { $0.setString("hi", forType: .string) }))
    }
}
