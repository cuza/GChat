import SwiftUI

/// The composer's GIF popover: trending when the field is empty, debounced search otherwise. A click sends at once.
struct GifPicker: View {
    let pick: (Attachment) -> Void
    let close: () -> Void
    @State private var key = Giphy.key
    @State private var query = ""
    @State private var gifs: [Giphy.Gif] = []
    @State private var status: String?
    var body: some View {
        VStack(spacing: 8) {
            if key == nil {
                ContentUnavailableView {
                    Label("No GIPHY API key", systemImage: "key")
                } description: {
                    Text("Add your key in Settings to search GIFs.")
                } actions: {
                    SettingsLink { Text("Open Settings…") }
                }
            } else {
                TextField("Search GIPHY", text: $query).textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(gifs) { gif in
                            Button { pick(gif.attachment); close() } label: { GifCell(url: gif.preview.url) }
                                .buttonStyle(.plain).help(gif.title).accessibilityLabel(gif.title.isEmpty ? "GIF" : gif.title)
                        }
                    }
                }
                .overlay { if let status { Text(status).foregroundStyle(.secondary).multilineTextAlignment(.center).padding() } }
                Text("Powered by GIPHY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)   // required by GIPHY's terms
            }
        }
        .padding(10).frame(width: 360, height: 420)
        .onExitCommand(perform: close)
        .task(id: query) { await load() }
    }
    private func load() async {
        guard let key else { return }
        if !query.isEmpty {   // debounce: a new keystroke cancels this task before the request (100 calls/hour on a beta key)
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
        }
        do {
            gifs = try await Giphy.gifs(matching: query, key: key)
            status = gifs.isEmpty ? "No GIFs found" : nil
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            gifs = []; status = error.localizedDescription
        }
    }
}

private struct GifCell: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            .frame(height: 90)
            .overlay { if let image { AnimatedImage(image: image) } }   // NSImageView, so the preview animates
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .task(id: url) { image = nil; if let loaded = await RemoteImage.image(url, px: 200), !Task.isCancelled { image = loaded } }
    }
}
