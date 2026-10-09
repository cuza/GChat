import CryptoKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One attachment in a bubble: images, GIFs and video posters inline; files and links as a chip.
/// `load(attachment, thumbnail)` returns the bytes (`ChatStore.attachmentData`). Clicks, drags and the menu are
/// handled by the row's `AttachmentHostView`.
struct AttachmentView: View {
    let attachment: Attachment
    let load: (Attachment, _ thumbnail: Bool) async throws -> Data
    var own = false   // in my bubble: a voice message draws in my bubble's text colour
    var transcriptOpen = false
    var toggleTranscript: () -> Void = {}
    var dismissCard: () -> Void = {}
    var clickCard: (Data, [Card.Input]) async -> Void = { _, _ in }
    @State private var loaded: (key: String, image: NSImage)?
    @State private var failedKey: String?
    /// The row view is recycled: only this attachment's picture or failure shows, and a cached picture shows on the
    /// first frame, without a placeholder in between.
    private var image: NSImage? { loaded?.key == key ? loaded?.image : ImageCache.cached(attachment) }
    private var failed: Bool { failedKey == key }
    private var key: String { ImageCache.key(attachment) }

    var body: some View {
        if attachment.kind == .voice { VoiceMessageView(attachment: attachment, own: own, load: load, transcriptOpen: transcriptOpen, toggleTranscript: toggleTranscript) }
        else if let card = attachment.card { CardView(card: card, dismiss: dismissCard, expanded: transcriptOpen, toggle: toggleTranscript, click: clickCard)
            .id(attachment.cacheKey) }   // a recycled row starts with empty fields
        else if attachment.kind == .image || attachment.kind == .video { media } else if attachment.domain != nil { card } else { chip }
    }

    /// Link preview: image on top, cropped to fill; then title, snippet and domain.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(.quaternary).frame(height: cardImageHeight)
                .overlay(alignment: .top) {   // top-aligned: a document preview shows its first lines
                    if let image { Image(nsImage: image).resizable().scaledToFill().transition(.opacity) }
                    else if failed {   // as Google Chat shows a file it can't preview (no access): its type's icon, large
                        Image(systemName: driveSymbol ?? "link").font(.system(size: driveSymbol == nil ? 13 : 56))
                            .foregroundStyle(own ? ink.opacity(0.8) : Color.secondary).frame(maxHeight: .infinity)
                    }
                }
                .overlay {
                    if attachment.isVideoLink {
                        Image(systemName: "play.circle.fill").font(.system(size: 40)).foregroundStyle(.white, .black.opacity(0.5))
                    }
                }
                .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(failed && attachment.untitledDrive ? "You don't have access to this file" : attachment.name).font(.callout.weight(.semibold)).lineLimit(2).foregroundStyle(text(.primary, 1))
                if let snippet = attachment.snippet, snippet != attachment.name {
                    Text(snippet).font(.caption).foregroundStyle(text(.secondary, 0.8)).lineLimit(2)
                }
                Text(attachment.domain ?? "").font(.caption2).foregroundStyle(text(.tertiary, 0.65)).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)   // the row sizes it (RowLayout.attachmentSize)
        .background(fill, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .help(attachment.url?.absoluteString ?? attachment.name)
        .task(id: attachment) { await loadThumbnail() }
    }
    private var cardImageHeight: CGFloat { attachment.cardImageHeight }
    private var media: some View {
        ZStack {
            if let image { AnimatedImage(image: image).transition(.opacity) } else {
                Rectangle().fill(.quaternary)
                if failed { Image(systemName: "photo").foregroundStyle(.secondary) } else { ProgressView().controlSize(.small) }
            }
            if attachment.kind == .video {
                Image(systemName: "play.circle.fill").font(.system(size: 40)).foregroundStyle(.white, .black.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // the row sizes it: mediaSize, narrowed to fit the bubble
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .help(attachment.name)
        .task(id: attachment) { await loadThumbnail() }
    }

    private var chip: some View {
        HStack(spacing: 8) {
            if attachment.kind == .call {   // as Google Chat shows a call: a video icon, red when missed
                Image(systemName: attachment.call == .missed ? "video.slash.fill" : "video.fill").font(.system(size: 18))
                    .foregroundStyle(attachment.call == .missed ? Color.red : own ? ink : Color.secondary).frame(width: 28, height: 28)   // my bubble's text colour on it bubble
            } else if let driveSymbol {
                Image(systemName: driveSymbol).font(.system(size: 20)).foregroundStyle(text(.secondary, 0.9)).frame(width: 28, height: 28)
            } else {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name).lineLimit(1).truncationMode(.middle).foregroundStyle(text(.primary, 1))
                Text(detail).font(.caption).foregroundStyle(text(.secondary, 0.8)).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: 280, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 10))
        .help(attachment.url?.absoluteString ?? attachment.name)
    }
    private var type: UTType? { attachment.utType }
    /// Card and chip background: set off from my bubble so its text stands out; a light tint elsewhere.
    private var fill: AnyShapeStyle { own ? AnyShapeStyle(Color(nsColor: BubblePalette.ownWell)) : AnyShapeStyle(.quaternary.opacity(0.6)) }
    /// Card and chip text: my bubble's text colour on it, the system's levels elsewhere.
    private var ink: Color { Color(nsColor: BubblePalette.ownInk) }
    private func text(_ level: HierarchicalShapeStyle, _ white: Double) -> AnyShapeStyle {
        own ? AnyShapeStyle(ink.opacity(white)) : AnyShapeStyle(level)
    }
    /// Google Docs, Sheets and Slides have no system file type: a symbol for each, and a page for other Drive-native files.
    private var driveSymbol: String? {
        let type = attachment.contentType
        guard type.hasPrefix("application/vnd.google-apps") || attachment.untitledDrive else { return nil }
        // Google Chat sends the editors' own names: kix (Docs), ritz (Sheets), punch (Slides).
        return type.hasSuffix(".spreadsheet") || type.hasSuffix(".ritz") ? "tablecells.fill"
            : type.hasSuffix(".presentation") || type.hasSuffix(".punch") ? "rectangle.on.rectangle.angled.fill" : "doc.fill"
    }
    private var icon: NSImage {
        if attachment.kind == .link && type == nil { return NSImage(systemSymbolName: "link", accessibilityDescription: nil) ?? NSImage() }
        return NSWorkspace.shared.icon(for: type ?? .data)
    }
    private var detail: String { attachment.detail }

    /// Fetches and decodes the picture unless it is cached; one that had to load fades in (0.2 s, as Telegram).
    private func loadThumbnail() async {
        let key = self.key
        guard image == nil else { return }
        do {
            guard let decoded = try await ImageCache.load(attachment, load) else { failedKey = key; return }
            withAnimation(.easeIn(duration: 0.2)) { loaded = (key, decoded) }
        } catch { if !(error is CancellationError) { failedKey = key } }
    }
}

/// Sizes `AttachmentView` draws at, known before any bytes load; `RowLayout` reserves the same.
extension Attachment {
    /// Known image size scaled to the 320-pt card width, capped so a tall image doesn't dominate the row.
    var cardImageHeight: CGFloat {
        guard let w = width, let h = height else { return 160 }
        return min(180, max(80, 320 * CGFloat(h) / CGFloat(w)))
    }
    /// Fits the known size into 320×240 so the row keeps its height while the bytes load.
    var mediaSize: CGSize {
        let w = CGFloat(width ?? 320), h = CGFloat(height ?? 240)
        let scale = min(1, 320 / w, 240 / h)
        return CGSize(width: max(60, w * scale), height: max(60, h * scale))
    }
    var utType: UTType? { UTType(mimeType: contentType) }
    // ponytail: the wire has no byte size; the chip shows the kind instead.
    /// A link to a video (YouTube), drawn with a play button over its picture.
    var isVideoLink: Bool { kind == .link && domain == "youtube.com" }
    var detail: String {
        if contentType == Self.calendarType { return "Google Calendar" }
        if contentType == Self.taskType { return "Google Tasks" }
        return kind == .call ? "Google Meet" : kind == .link ? url?.host() ?? "Link" : utType?.localizedDescription ?? "File"
    }
    static let calendarType = "text/calendar", taskType = "application/x-google-task"
    /// A Drive file Google Chat named only by its kind: when its preview fails, the viewer can't open it, and the card says so.
    static let untitledDrive = "Google Drive file"
    var untitledDrive: Bool { kind == .link && [Self.untitledDrive, "Google Doc", "Google Sheet", "Google Slides", "Google Form"].contains(name) }
}

/// Decoded attachment thumbnails, shared by the timeline, its prefetch and the info panel.
@MainActor enum ImageCache {
    static let shared: NSCache<NSString, NSImage> = { let cache = NSCache<NSString, NSImage>(); cache.countLimit = 200; return cache }()
    private static var inFlight: [String: Task<NSImage?, Error>] = [:]
    static func key(_ attachment: Attachment) -> String { attachment.cacheKey ?? (attachment.thumbnailURL ?? attachment.url)?.absoluteString ?? attachment.name }
    /// Where fetched pictures are kept between launches, by key: the app's folder in Caches, as macOS expects (left out
    /// of backups, and cleared by the system when space runs low). Debug builds keep their own, as with the launch cache;
    /// tests and the demo workspace keep none.
    #if DEBUG
    static var directory: URL? = URL.cachesDirectory.appending(path: "\(Bundle.main.bundleIdentifier ?? "dev.cuza.Parley")/Images-debug")
    #else
    static var directory: URL? = URL.cachesDirectory.appending(path: "\(Bundle.main.bundleIdentifier ?? "dev.cuza.Parley")/Images")
    #endif
    /// At most this much on disk; past it, the least recently used pictures go first.
    nonisolated static let diskLimit = 500_000_000
    private static func file(_ key: String) -> URL? {
        directory?.appending(path: SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined())
    }
    /// Once a launch, off the main thread: removes pictures not used for 30 days, then the least recently used until the
    /// rest fit `diskLimit`. Using a picture touches its file.
    private static let prune: Void = {
        guard let directory else { return }
        Task.detached(priority: .background) { prune(directory, limit: diskLimit) }
    }()
    nonisolated static func prune(_ directory: URL, limit: Int, now: Date = .now) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []).map { file in
            let values = try? file.resourceValues(forKeys: keys)
            return (file, used: values?.contentModificationDate ?? .distantPast, size: values?.totalFileAllocatedSize ?? 0)
        }.sorted { $0.used > $1.used }   // most recently used first
        var total = 0
        for file in files {
            total += file.size
            if total > limit || file.used < now.addingTimeInterval(-30 * 86_400) { try? FileManager.default.removeItem(at: file.0) }
        }
    }
    static func cached(_ attachment: Attachment) -> NSImage? { shared.object(forKey: key(attachment) as NSString) }
    /// The thumbnail, from the cache or fetched and decoded off the main thread at display size, then cached.
    /// Concurrent requests for one picture (a row and the prefetch) share a single fetch. Nil: the bytes are not an image.
    static func load(_ attachment: Attachment, _ data: @escaping (Attachment, _ thumbnail: Bool) async throws -> Data) async throws -> NSImage? {
        if let cached = cached(attachment) { return cached }
        let key = key(attachment)
        if let running = inFlight[key] { return try await running.value }
        let maxPixels = attachment.displayPixels
        _ = prune
        let file = file(key)
        let task = Task<NSImage?, Error> {
            defer { inFlight[key] = nil }
            // From disk when an earlier launch kept it (touched, so pruning keeps what is used), else fetched and kept.
            let kept = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let file, let bytes = try? Data(contentsOf: file), let image = decode(bytes, maxPixels: maxPixels) else { return nil }
                try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path)
                return image
            }.value
            if let kept { shared.setObject(kept, forKey: key as NSString); return kept }
            let bytes = try await data(attachment, true)
            guard let image = await Task.detached(priority: .userInitiated, operation: { () -> NSImage? in
                guard let image = decode(bytes, maxPixels: maxPixels) else { return nil }
                if let file {
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? bytes.write(to: file, options: .atomic)
                }
                return image
            }).value else { return nil }
            shared.setObject(image, forKey: key as NSString)
            return image
        }
        inFlight[key] = task
        return try await task.value
    }
    /// Downsampled to `maxPixels` on its longer side and decoded now, so drawing it costs nothing on the main thread.
    /// An animated GIF is kept whole: `AnimatedImage` plays its frames.
    nonisolated static func decode(_ data: Data, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if CGImageSourceGetCount(source) > 1 { return NSImage(data: data) }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

extension Attachment {
    /// The longer side, in pixels, that the timeline draws this picture at: the media frame, or the link card,
    /// on the sharpest screen attached.
    // ponytail: a card is cropped to fill 320 pt wide, so 640 pt covers all but extreme panoramas.
    @MainActor var displayPixels: Int {
        let points = kind == .image || kind == .video ? max(mediaSize.width, mediaSize.height) : 640
        return Int(points * (NSScreen.screens.map(\.backingScaleFactor).max() ?? 2))
    }
}

/// NSImageView animates GIFs; SwiftUI's Image shows only the first frame.
struct AnimatedImage: NSViewRepresentable {
    let image: NSImage
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) { if view.image !== image { view.image = image } }
}
