import AppKit
import CryptoKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// Attachments as files, for the timeline's native file handling (as Telegram for macOS and Messages do):
/// Quick Look with ←/→ through the conversation's media and files, drag out to Finder or another app, and the
/// attachment menu (Save, Copy, Show in Finder). Full-size bytes come from `load` (`ChatStore.attachmentData`, which
/// adds auth) and are kept under Caches as `<hash of the URL>/<file name>`, so a second open reads the file.
@MainActor final class AttachmentFiles: NSObject {
    static let defaultFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "\(Bundle.main.bundleIdentifier ?? "dev.cuza.Parley")/Attachments")
    /// Where Save put each attachment this launch: the menu then offers Show in Finder.
    static var saved: [Attachment: URL] = [:]

    let folder: URL
    var load: (Attachment, _ thumbnail: Bool) async throws -> Data
    /// The conversation's messages, oldest first: Quick Look's ←/→ order.
    var messages: () -> [Message] = { [] }
    /// Made first responder before Quick Look opens, so the panel finds its controller (`TimelineTableView`).
    weak var responder: NSResponder?
    private var downloads: [URL: Task<URL, Error>] = [:]
    private(set) var previewItems: [PreviewItem] = []
    private(set) var previewIndex = 0

    init(folder: URL = defaultFolder, load: @escaping (Attachment, _ thumbnail: Bool) async throws -> Data) {
        self.folder = folder
        self.load = load
    }

    // MARK: Cache
    /// The attachment's name, safe as a file name, with an extension from its type when it has none.
    nonisolated static func fileName(_ attachment: Attachment) -> String {
        var name = attachment.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "attachment" }
        if (name as NSString).pathExtension.isEmpty, let ext = attachment.utType?.preferredFilenameExtension { name += ".\(ext)" }
        return name
    }
    /// The file for `attachment`: the local file of an unsent echo, otherwise its place in the cache.
    func cacheURL(_ attachment: Attachment) -> URL {
        if let url = attachment.url, url.isFileURL { return url }
        let key = attachment.url?.absoluteString ?? "\(attachment.name)|\(attachment.contentType)"
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return folder.appending(path: hash).appending(path: Self.fileName(attachment))
    }
    func cachedFile(_ attachment: Attachment) -> URL? {
        let url = cacheURL(attachment)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    /// The attachment as a file, downloaded once; concurrent callers share the download.
    func file(_ attachment: Attachment) async throws -> URL {
        if let url = attachment.url, url.isFileURL { return url }
        if let cached = cachedFile(attachment) { return cached }
        let url = cacheURL(attachment)
        if let running = downloads[url] { return try await running.value }
        let task = Task { [load] in
            let data = try await load(attachment, false)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        }
        downloads[url] = task
        defer { downloads[url] = nil }
        return try await task.value
    }

    // MARK: Save and copy
    /// `name` in `folder`, numbered ("a 2.txt") when taken, as Finder and Safari name downloads.
    nonisolated static func unusedURL(_ name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = folder.appending(path: name), n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = folder.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
        }
        return url
    }
    /// Copies the attachment into `folder` under an unused name and remembers it for Show in Finder.
    @discardableResult func save(_ attachment: Attachment, in folder: URL) async throws -> URL {
        let source = try await file(attachment)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = Self.unusedURL(Self.fileName(attachment), in: folder)
        try FileManager.default.copyItem(at: source, to: target)
        Self.saved[attachment] = target
        return target
    }
    private func saveToDownloads(_ attachment: Attachment) async {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        do {
            let target = try await save(attachment, in: downloads)
            // Bounces the Downloads stack in the Dock, as Safari does.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: target.path)
        } catch { NSSound.beep() }
    }
    private func saveAs(_ attachment: Attachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.fileName(attachment)
        let window = NSApp.keyWindow
        let chosen: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let target = panel.url, let self else { return }
            Task {
                do {
                    let source = try await self.file(attachment)
                    // The panel already asked whether to replace.
                    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                    try FileManager.default.copyItem(at: source, to: target)
                    Self.saved[attachment] = target
                } catch { NSSound.beep() }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: chosen) } else { chosen(panel.runModal()) }
    }
    /// The file's URL (Finder pastes the file), and for an image its bytes too (Preview, Notes, Mail paste the image).
    nonisolated static func pasteboardItem(file: URL, attachment: Attachment) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        if attachment.kind == .image, let type = attachment.utType ?? UTType(filenameExtension: file.pathExtension),
           let data = try? Data(contentsOf: file) {
            item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        }
        return item
    }
    private func copy(_ attachment: Attachment) async {
        guard let file = try? await file(attachment) else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([Self.pasteboardItem(file: file, attachment: attachment)])
    }

    // MARK: Menu
    /// The attachment's section of the message menu; none for link previews.
    func menuItems(_ attachment: Attachment) -> [NSMenuItem] {
        guard attachment.kind != .link else { return [] }
        var items = [
            ClosureMenuItem("Quick Look") { [weak self] in self?.preview(attachment) },
            ClosureMenuItem("Save to Downloads") { [weak self] in Task { await self?.saveToDownloads(attachment) } },
            ClosureMenuItem("Save As…") { [weak self] in self?.saveAs(attachment) },
            ClosureMenuItem(attachment.kind == .image ? "Copy Image" : "Copy File") { [weak self] in Task { await self?.copy(attachment) } },
        ]
        if let saved = Self.saved[attachment], FileManager.default.fileExists(atPath: saved.path) {
            items.append(ClosureMenuItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) })
        }
        return items
    }

    // MARK: Quick Look
    /// One attachment in the panel; its URL is set once the file is downloaded.
    final class PreviewItem: NSObject, QLPreviewItem {
        let attachment: Attachment
        var file: URL?
        init(_ attachment: Attachment, file: URL?) { self.attachment = attachment; self.file = file }
        var previewItemURL: URL! { file }
        var previewItemTitle: String! { AttachmentFiles.fileName(attachment) }
    }
    /// Lists the conversation's media and files with `attachment` current; false for a link, which has no file.
    func preparePreview(_ attachment: Attachment) -> Bool {
        guard !attachment.opensInBrowser else { return false }
        var all = messages().flatMap(\.attachments).filter { !$0.opensInBrowser }
        if !all.contains(attachment) { all = [attachment] }
        previewItems = all.map { PreviewItem($0, file: cachedFile($0)) }
        previewIndex = all.firstIndex(of: attachment) ?? 0
        return true
    }
    /// Downloads the item's file and points the item at it.
    func fetch(_ item: PreviewItem) async throws {
        item.file = try await file(item.attachment)
    }
    /// Opens Quick Look on `attachment` (a link opens in the browser instead).
    func preview(_ attachment: Attachment) {
        guard preparePreview(attachment) else { if let url = attachment.url { NSWorkspace.shared.open(url) }; return }
        if let responder, let view = responder as? NSView { view.window?.makeFirstResponder(responder) }
        let panel = QLPreviewPanel.shared()!
        if panel.isVisible && panel.dataSource === self {
            panel.reloadData()
            panel.currentPreviewItemIndex = previewIndex
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }
    /// Space on the timeline: closes the panel, or reopens it on the last previewed attachment.
    func togglePreview() -> Bool {
        guard let panel = QLPreviewPanel.shared() else { return false }
        if panel.isVisible { panel.orderOut(nil); return true }
        guard !previewItems.isEmpty else { return false }
        panel.makeKeyAndOrderFront(nil)
        return true
    }
    /// Called by the controlling responder (`TimelineTableView`).
    func beginControl(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = previewIndex
    }
    func endControl(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    // MARK: Drag
    /// A file promise for the attachment, which also offers the file's URL when it is already cached
    /// (the shape of Apple's file-promise sample).
    final class Promise: NSFilePromiseProvider {
        var attachment: Attachment?
        var cached: URL?
        override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
            super.writableTypes(for: pasteboard) + (cached == nil ? [] : [.fileURL])
        }
        override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
            if type == .fileURL, let cached { return cached.absoluteString }
            return super.pasteboardPropertyList(forType: type)
        }
    }
    func dragWriter(_ attachment: Attachment) -> Promise {
        let type = attachment.utType ?? UTType(filenameExtension: (Self.fileName(attachment) as NSString).pathExtension) ?? .data
        let promise = Promise(fileType: type.identifier, delegate: self)
        promise.attachment = attachment
        promise.cached = cachedFile(attachment)
        return promise
    }
}

extension AttachmentFiles: @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItems.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let item = previewItems[index]
        if item.file == nil {   // fetched when the panel shows it; ←/→ fetch the next one
            Task { [weak panel] in
                guard (try? await fetch(item)) != nil, let panel, panel.currentPreviewItem as? PreviewItem === item else { return }
                panel.refreshCurrentPreviewItem()
            }
        }
        return item
    }
}

extension AttachmentFiles: NSFilePromiseProviderDelegate {
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider as? Promise)?.attachment.map(Self.fileName) ?? "attachment"
    }
    /// Runs when the drop lands: downloads (or reuses the cache), then copies to where the receiver asked.
    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let attachment = (provider as? Promise)?.attachment else { return completionHandler(CocoaError(.fileNoSuchFile)) }
        nonisolated(unsafe) let done = completionHandler   // AppKit's handler may be called from any thread
        Task {
            do {
                try FileManager.default.copyItem(at: try await file(attachment), to: url)
                done(nil)
            } catch { done(error) }
        }
    }
}

/// An attachment in a row. It takes the clicks itself (AppKit, not the SwiftUI content): a click opens Quick Look,
/// a drag carries the file out, and a right-click opens the message menu with the attachment's items.
final class AttachmentHostView: NSHostingView<AttachmentView> {
    var attachment: Attachment?
    weak var files: AttachmentFiles?
    private var mouseDown: NSEvent?

    /// A voice message's controls (play, seek, speed) are SwiftUI's own; other attachments are one clickable, draggable piece.
    private var interactive: Bool { attachment?.kind == .voice || attachment?.kind == .card }   // their own controls and links
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return interactive || hit == nil ? hit : self
    }
    override func mouseDown(with event: NSEvent) { if interactive { super.mouseDown(with: event) } else { mouseDown = event } }
    override func mouseDragged(with event: NSEvent) {
        if interactive { return super.mouseDragged(with: event) }
        guard let start = mouseDown, let attachment, !attachment.opensInBrowser, let files else { return }
        let a = start.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 4 else { return }
        mouseDown = nil
        let item = NSDraggingItem(pasteboardWriter: files.dragWriter(attachment))
        item.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [item], event: start, source: CopyDragSource.shared)
    }
    override func mouseUp(with event: NSEvent) {
        if interactive { return super.mouseUp(with: event) }
        defer { mouseDown = nil }
        guard mouseDown != nil, let attachment, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if let files { files.preview(attachment) } else if attachment.opensInBrowser, let url = attachment.url { NSWorkspace.shared.open(url) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let row = superview as? MessageRowView, row.row != nil else { return nil }
        return row.contextMenu(attachment: attachment)
    }
    override func accessibilityPerformPress() -> Bool {
        guard let attachment, let files else { return false }
        files.preview(attachment)
        return true
    }
    private func snapshot() -> NSImage {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage() }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

/// NSHostingView is a dragging source of its own (SwiftUI's drags); attachment drags offer a copy.
@MainActor private final class CopyDragSource: NSObject, NSDraggingSource {
    static let shared = CopyDragSource()
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
