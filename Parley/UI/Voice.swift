import AVFoundation
import AppKit
import SwiftUI

/// Voice levels as Google Chat keeps them: one 0…100 value per 100 ms of audio.
enum Waveform {
    static let interval: TimeInterval = 0.1
    /// `samples` fitted to `count` bars: each bar the loudest sample it covers; fewer samples than bars are stretched.
    static func bars(_ samples: [Int], count: Int) -> [Int] {
        guard !samples.isEmpty, count > 0 else { return [] }
        return (0..<count).map { bar in
            let start = bar * samples.count / count, end = max(start + 1, (bar + 1) * samples.count / count)
            return samples[start..<min(end, samples.count)].max() ?? 0
        }
    }
    /// A meter's peak power (dBFS) as a 0…100 level.
    static func level(decibels: Float) -> Int { level(amplitude: pow(10, decibels / 20)) }
    static func level(amplitude: Float) -> Int { Int((min(1, max(0, amplitude)) * 100).rounded()) }
    /// Levels read from the audio itself, for a voice message sent without any. Nil: not audio AVFoundation reads.
    nonisolated static func levels(ofAudio data: Data) -> [Int]? {
        let file = FileManager.default.temporaryDirectory.appending(path: "Parley-voice-\(UUID().uuidString).\(data.starts(with: Data("RIFF".utf8)) ? "wav" : "m4a")")
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? data.write(to: file)) != nil, let audio = try? AVAudioFile(forReading: file) else { return nil }
        let chunk = AVAudioFrameCount(max(1, audio.processingFormat.sampleRate * interval))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: chunk) else { return nil }
        var levels: [Int] = []
        while (try? audio.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] {
            var peak: Float = 0
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channel[i])) }
            levels.append(level(amplitude: peak))
        }
        return levels
    }
    static func time(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down)).clamped(to: 0...359_999)
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}
private extension Int { func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(range.upperBound, Swift.max(range.lowerBound, self)) } }

/// The voice row's size in a bubble, known before the audio loads; `RowLayout` reserves it.
enum VoiceLayout {
    static let button: CGFloat = 40, gap: CGFloat = 10, height: CGFloat = 42
    /// Longer messages get a longer waveform, as Telegram draws them.
    static func waveWidth(_ voice: Voice?, maxWidth: CGFloat) -> CGFloat {
        max(40, min(maxWidth - button - gap, min(200, max(110, 70 + 4 * (voice?.duration ?? 0)))))
    }
    /// Closed, the transcript is one line with "View transcript" beside it; open, all of it with "Hide transcript" under it.
    static func size(_ voice: Voice?, maxWidth: CGFloat, open: Bool = false) -> CGSize {
        let width = button + gap + waveWidth(voice, maxWidth: maxWidth)
        guard let transcript = voice?.transcript else { return CGSize(width: width, height: height) }
        let toggle = RowLayout.measure(toggleText(open), width: width).height
        guard open else { return CGSize(width: width, height: height + 4 + max(toggle, RowLayout.measure(transcriptText("x"), width: width).height)) }
        let text = RowLayout.measure(transcriptText(transcript), width: width).height
        return CGSize(width: width, height: ceil(height + 4 + text + 2 + toggle))
    }
    static func toggleText(_ open: Bool) -> NSAttributedString {
        RowLayout.styled(open ? "Hide transcript" : "View transcript", .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium), oneLine: true)
    }
    static func transcriptText(_ transcript: String) -> NSAttributedString {
        RowLayout.styled(transcript, .preferredFont(forTextStyle: .caption1))
    }
}

/// Plays voice messages, one at a time: starting one stops the one playing. Shared by every timeline.
@MainActor @Observable final class VoicePlayback {
    static let shared = VoicePlayback()
    private(set) var current: String?        // the attachment key (`ImageCache.key`) loaded into the player
    private(set) var isPlaying = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var rate: Float = 1
    /// Levels computed from the audio of messages sent without any, by attachment key.
    private(set) var computed: [String: [Int]] = [:]
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var loading: String?
    @ObservationIgnored private let audio: NSCache<NSString, NSData> = { let cache = NSCache<NSString, NSData>(); cache.countLimit = 20; return cache }()
    static let rates: [Float] = [1, 1.5, 2]

    var progress: Double { duration > 0 ? min(1, elapsed / duration) : 0 }
    /// The audio, fetched once and kept for a few messages.
    func data(_ key: String, load: () async throws -> Data) async throws -> Data {
        if let cached = audio.object(forKey: key as NSString) { return cached as Data }
        let data = try await load()
        audio.setObject(data as NSData, forKey: key as NSString)
        return data
    }
    /// Play or pause `key`; another message playing stops.
    func toggle(_ key: String, load: @escaping () async throws -> Data) async {
        if current == key, let player {
            if isPlaying { pause() } else { player.play(); isPlaying = true; startTimer() }
            return
        }
        await start(key, at: 0, load: load)
    }
    /// A click or drag on the waveform: jumps there, starting the message if another (or none) was loaded.
    func seek(_ key: String, to fraction: Double, load: @escaping () async throws -> Data) async {
        let fraction = min(1, max(0, fraction))
        if current == key, let player {
            player.currentTime = fraction * player.duration
            elapsed = player.currentTime
            return
        }
        await start(key, at: fraction, load: load)
    }
    func pause() {
        player?.pause(); isPlaying = false; timer?.invalidate(); timer = nil
        elapsed = player?.currentTime ?? elapsed
    }
    func cycleRate() {
        rate = Self.rates[((Self.rates.firstIndex(of: rate) ?? 0) + 1) % Self.rates.count]
        player?.rate = rate
    }
    /// Loads the bytes into a new player and starts it at `fraction`; a failed load leaves nothing playing.
    func play(_ key: String, data: Data, at fraction: Double = 0) throws {
        stop()
        let player = try AVAudioPlayer(data: data)
        player.enableRate = true
        player.rate = rate
        player.prepareToPlay()
        player.currentTime = fraction * player.duration
        self.player = player
        current = key; duration = player.duration; elapsed = player.currentTime
        isPlaying = player.play()
        startTimer()
    }
    func stop() {
        player?.stop(); player = nil
        timer?.invalidate(); timer = nil
        current = nil; isPlaying = false; elapsed = 0; duration = 0
    }
    /// Levels for a message sent without them, read from its audio once (best effort).
    func computeWaveform(_ key: String, load: @escaping () async throws -> Data) async {
        guard computed[key] == nil, let data = try? await data(key, load: load) else { return }
        let levels = await Task.detached(priority: .utility) { Waveform.levels(ofAudio: data) }.value
        computed[key] = levels ?? []
    }
    private func start(_ key: String, at fraction: Double, load: @escaping () async throws -> Data) async {
        guard loading != key else { return }
        loading = key; defer { loading = nil }
        pause()
        guard let data = try? await data(key, load: load) else { return }
        try? play(key, data: data, at: fraction)
    }
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }
    private func tick() {
        guard let player else { return }
        if player.isPlaying { elapsed = player.currentTime; return }
        // Played to the end: back to the start, as Telegram leaves it.
        isPlaying = false; elapsed = 0; player.currentTime = 0
        timer?.invalidate(); timer = nil
    }
}

/// A voice message in a bubble, Telegram style: a round play button, the waveform (filled as it plays; click or drag
/// to seek), the time, a speed toggle while it is the one loaded, and the transcript when the server has one.
struct VoiceMessageView: View {
    let attachment: Attachment
    let own: Bool
    let load: (Attachment, _ thumbnail: Bool) async throws -> Data
    var transcriptOpen = false
    var toggleTranscript: () -> Void = {}
    @State private var waveWidth: CGFloat = 1
    private var playback: VoicePlayback { .shared }
    private var key: String { ImageCache.key(attachment) }
    private var voice: Voice? { attachment.voice }
    private var active: Bool { playback.current == key }
    private var samples: [Int] { (voice?.waveform.isEmpty ?? true) ? playback.computed[key] ?? [] : voice?.waveform ?? [] }
    private var loader: () async throws -> Data { { [attachment, load] in try await load(attachment, false) } }
    private var tint: Color { own ? ink : .accentColor }
    private var ink: Color { Color(nsColor: BubblePalette.ownInk) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: VoiceLayout.gap) {
                Button { Task { await playback.toggle(key, load: loader) } } label: {
                    Image(systemName: active && playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(own ? Color(nsColor: BubblePalette.own) : .white)
                        .frame(width: VoiceLayout.button, height: VoiceLayout.button)
                        .background(tint, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(active && playback.isPlaying ? "Pause voice message" : "Play voice message")
                VStack(alignment: .leading, spacing: 4) {
                    bars
                    HStack(spacing: 6) {
                        Text(Waveform.time(active && playback.elapsed > 0 ? playback.elapsed : total))
                            .font(.caption.monospacedDigit()).foregroundStyle(own ? ink.opacity(0.8) : .secondary)
                        if active {
                            Button { playback.cycleRate() } label: {
                                Text(playback.rate == 1.5 ? "1.5×" : "\(Int(playback.rate))×").font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(tint.opacity(0.2), in: Capsule()).foregroundStyle(tint)
                            }.buttonStyle(.plain).help("Playback speed").accessibilityLabel("Playback speed")
                        }
                    }
                }
            }
            if let transcript = voice?.transcript {   // as Google Chat shows it: one line, or all of it on request
                let toggle = Button(transcriptOpen ? "Hide transcript" : "View transcript", action: toggleTranscript)
                    .buttonStyle(.plain).font(.system(size: NSFont.smallSystemFontSize, weight: .medium)).foregroundStyle(tint)
                if transcriptOpen {
                    Text(transcript).font(.caption).foregroundStyle(own ? ink.opacity(0.9) : .secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    toggle.frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    HStack(spacing: 8) {
                        Text(transcript).font(.caption).foregroundStyle(own ? ink.opacity(0.9) : .secondary).lineLimit(1)
                        toggle.fixedSize()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)   // the row sizes it (VoiceLayout.size)
        .task(id: key) { if voice?.waveform.isEmpty ?? true { await playback.computeWaveform(key, load: loader) } }
    }
    private var total: TimeInterval { active && playback.duration > 0 ? playback.duration : voice?.duration ?? 0 }
    /// 2-pt bars 1 pt apart; the played part in the bubble's strong colour.
    private var bars: some View {
        let samples = self.samples, progress = active ? playback.progress : 0
        let played = tint, unplayed = own ? ink.opacity(0.45) : Color.secondary.opacity(0.45)
        return Canvas { context, size in
            let levels = Waveform.bars(samples.isEmpty ? [0] : samples, count: max(1, Int(size.width / 3)))
            let peak = CGFloat(max(1, levels.max() ?? 1))
            for (index, level) in levels.enumerated() {
                let height = max(2, size.height * CGFloat(level) / peak)
                let rect = CGRect(x: CGFloat(index) * 3, y: size.height - height, width: 2, height: height)
                let isPlayed = (Double(index) + 0.5) / Double(levels.count) <= progress
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(isPlayed ? played : unplayed))
            }
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { waveWidth = $0 }
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            let fraction = value.location.x / max(1, waveWidth)
            Task { await playback.seek(key, to: fraction, load: loader) }
        })
        .accessibilityLabel("Waveform")
    }
}

/// Records a voice message: AAC in an .m4a, mono, as Google Chat's own recordings, with one level per 100 ms for the waveform.
@MainActor @Observable final class VoiceRecorder {
    enum Failure: LocalizedError {
        case microphoneDenied, couldNotStart
        var errorDescription: String? {
            switch self {
            case .microphoneDenied: "Parley can’t use the microphone. Allow it in System Settings ▸ Privacy & Security ▸ Microphone."
            case .couldNotStart: "Recording couldn’t start."
            }
        }
    }
    struct Recording { var file: URL; var duration: TimeInterval; var levels: [Int] }
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var levels: [Int] = []
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var timer: Timer?
    /// Shorter ones are dropped, as a slip of the click.
    static let minimumDuration: TimeInterval = 0.5
    static let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                                          AVEncoderBitRateKey: 64_000]

    func start() async throws {
        guard !isRecording else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined: guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Failure.microphoneDenied }
        default: throw Failure.microphoneDenied
        }
        VoicePlayback.shared.pause()
        let folder = FileManager.default.temporaryDirectory.appending(path: "Parley Uploads/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recorder = try AVAudioRecorder(url: folder.appending(path: Voice.fileName()), settings: Self.settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw Failure.couldNotStart }
        self.recorder = recorder
        isRecording = true; elapsed = 0; levels = []
        timer = Timer.scheduledTimer(withTimeInterval: Waveform.interval, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
    }
    /// Ends the recording; nil when it was too short to send (the file is then removed).
    func finish() -> Recording? {
        guard let recorder else { return nil }
        let duration = recorder.currentTime, levels = levels
        end()
        recorder.stop()
        guard duration >= Self.minimumDuration else { recorder.deleteRecording(); return nil }
        return Recording(file: recorder.url, duration: duration, levels: levels)
    }
    func cancel() {
        guard let recorder else { return }
        end()
        recorder.stop(); recorder.deleteRecording()
    }
    private func end() {
        timer?.invalidate(); timer = nil
        recorder = nil; isRecording = false
    }
    private func sample() {
        guard let recorder else { return }
        recorder.updateMeters()
        levels.append(Waveform.level(decibels: recorder.peakPower(forChannel: 0)))
        elapsed = recorder.currentTime
    }
}

/// The composer while recording: a pulsing red dot, the time, and the last few seconds of levels.
struct RecordingBar: View {
    let recorder: VoiceRecorder
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(.red).frame(width: 9, height: 9).opacity(pulse ? 0.3 : 1)
                .animation(.easeInOut(duration: 0.6).repeatForever(), value: pulse)
                .onAppear { pulse = true }
            Text(Waveform.time(recorder.elapsed)).font(.body.monospacedDigit())
            Canvas { context, size in
                let count = Int(size.width / 3), recent = Array(recorder.levels.suffix(count))
                for (index, level) in recent.enumerated() {
                    let height = max(2, size.height * CGFloat(level) / 100)
                    let rect = CGRect(x: size.width - CGFloat(recent.count - index) * 3, y: (size.height - height) / 2, width: 2, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.accentColor))
                }
            }.frame(height: 24)
            Text("Esc to cancel").font(.caption).foregroundStyle(.tertiary).fixedSize()
        }
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine).accessibilityLabel("Recording voice message")
    }
}
