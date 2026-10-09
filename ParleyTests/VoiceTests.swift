import Foundation
import SwiftProtobuf
import Testing
@testable import Parley

struct VoiceMappingTests {
    private func upload(_ name: String, type: String, configure: (inout Dynamite_UploadMetadata) -> Void = { _ in }) -> Dynamite_Annotation {
        .with { a in
            a.uploadMetadata.attachmentToken = "tok"; a.uploadMetadata.contentName = name; a.uploadMetadata.contentType = type
            configure(&a.uploadMetadata)
        }
    }
    @Test func voiceMetadataMakesAVoiceMessage() throws {
        // As Google Chat sends one: 2.085 s, a level per 100 ms, and later a transcript.
        let annotation = upload("UserRecording_1.m4a", type: "audio/mpeg") {
            $0.voiceMessageMetadata = .with { $0.duration.seconds = 2; $0.duration.nanos = 85_333_333; $0.waveform = [2, 40, 100, 130, -5] }
            $0.transcript = "hello there"; $0.transcriptionStatus = 3
        }
        let attachment = try #require(DynamiteMapper.attachment(annotation))
        #expect(attachment.kind == .voice && attachment.thumbnailURL == nil && attachment.url != nil)
        let voice = try #require(attachment.voice)
        #expect(abs(voice.duration - 2.085333333) < 1e-6)
        #expect(voice.waveform == [2, 40, 100, 100, 0])   // clamped to 0…100
        #expect(voice.transcript == "hello there")
    }
    @Test func aRecordingWithoutMetadataIsStillAVoiceMessage() throws {
        let attachment = try #require(DynamiteMapper.attachment(upload("UserRecording_1700000000123.m4a", type: "audio/mpeg")))
        #expect(attachment.kind == .voice && attachment.voice == Voice(duration: 0, waveform: [], transcript: nil))
        // Other audio files stay files.
        #expect(DynamiteMapper.attachment(upload("song.mp3", type: "audio/mpeg"))?.kind == .file)
        #expect(DynamiteMapper.attachment(upload("song.mp3", type: "audio/mpeg"))?.voice == nil)
    }
    @Test func voiceSurvivesTheLaunchCacheAndOldEntriesDecode() throws {
        let voice = Attachment(name: "UserRecording_1.m4a", contentType: "audio/mpeg", kind: .voice, voice: Voice(duration: 3, waveform: [1, 2], transcript: "hi"))
        #expect(try JSONDecoder().decode(Attachment.self, from: JSONEncoder().encode(voice)) == voice)
        let old = Data(#"{"name":"a.pdf","contentType":"application/pdf","kind":"file"}"#.utf8)
        #expect(try JSONDecoder().decode(Attachment.self, from: old).voice == nil)
    }
    @Test func recordingsAreNamedAsGoogleChatNamesThem() {
        #expect(Voice.fileName(at: Date(timeIntervalSince1970: 1_700_000_000.123)) == "UserRecording_1700000000123.m4a")
        #expect(QuotedMessage.summary(text: "", attachments: [Attachment(name: "x", kind: .voice)]) == "Voice message")
    }
}

/// The send goes through the global stub registry, so it joins the serialized AuthTests suite.
extension AuthTests {
    @Test func voiceUploadIsNamedAndTypedLikeGoogleChats() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ParleyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "UserRecording_1700000000000.m4a")
        try FakeBackend.wav([0, 1, 2]).write(to: file)
        let recording = Attachment(name: file.lastPathComponent, contentType: Voice.contentType, kind: .voice, url: file, voice: Voice(duration: 1))
        let (backend, exchange) = try await Self.connected(try Self.uploadReplies(Self.uploadedMetadata))
        let uploaded = try await backend.upload(recording, to: "space/AAAA", thread: nil)
        let start = try #require(exchange.requests.dropLast().last)
        #expect(start.value(forHTTPHeaderField: "X-Goog-Upload-File-Name") == "UserRecording_1700000000000.m4a")
        #expect(start.value(forHTTPHeaderField: "X-Goog-Upload-Content-Type") == "audio/mpeg")
        #expect(uploaded.voice == recording.voice && uploaded.kind == .voice)
    }
    @Test func voiceSendCarriesDurationAndWaveformInField18() async throws {
        let topic = try Self.proto(Dynamite_CreateTopicResponse.with { $0.topic.replies = [Self.message("m9", topic: "m9", at: 5, by: "me")] })
        let (backend, exchange) = try await Self.connected([topic])
        let server = Dynamite_UploadMetadata.with { $0.attachmentToken = "tok"; $0.contentName = "UserRecording_1.m4a"; $0.contentType = "audio/mpeg" }
        var voice = Attachment(name: "UserRecording_1.m4a", contentType: "audio/mpeg", kind: .voice, url: URL(fileURLWithPath: "/tmp/v.m4a"),
                               voice: Voice(duration: 2.085333333, waveform: [2, 50, 100]))
        voice.uploadToken = (try server.serializedBytes() as Data).base64EncodedString()
        _ = try await backend.send(MessageDraft(text: "", localID: "local-v", uploads: [voice]), to: "space/AAAA", thread: nil)

        let request = try Dynamite_CreateTopicRequest(serializedBytes: Self.body(try #require(exchange.requests.first { $0.url?.path == "/api/create_topic" })))
        let chip = try #require(request.annotations.first)
        #expect(request.annotations.count == 1 && chip.type == .uploadMetadata)
        #expect(chip.uploadMetadata.attachmentToken == "tok" && chip.uploadMetadata.contentName == "UserRecording_1.m4a")
        #expect(chip.uploadMetadata.contentType == "audio/mpeg")
        let meta = chip.uploadMetadata.voiceMessageMetadata
        #expect(meta.duration.seconds == 2 && meta.duration.nanos == 85_333_333)
        #expect(meta.waveform == [2, 50, 100])

        // Under a second, the seconds stay unset, as Google Chat sends them ([null, nanos]).
        let short = DynamiteMapper.uploadAnnotation({ var v = voice; v.voice = Voice(duration: 0.085333333, waveform: [2]); return v }())
        #expect(short?.uploadMetadata.voiceMessageMetadata.duration.hasSeconds == false)
        #expect(short?.uploadMetadata.voiceMessageMetadata.duration.nanos == 85_333_333)
    }
}

@MainActor struct VoiceStoreTests {
    @Test func aRecordingIsSentAloneAsAVoiceUpload() async throws {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        let id = try #require(store.selectedID)
        let file = FileManager.default.temporaryDirectory.appending(path: "UserRecording_\(UUID().uuidString).m4a")
        try FakeBackend.wav([0, 1]).write(to: file)
        await store.sendVoice(file, duration: 1.5, waveform: [3, 4], conversation: id)
        let upload = try #require(await fake.sentDrafts.last?.uploads.first)
        #expect(upload.kind == .voice && upload.name == file.lastPathComponent && upload.contentType == "audio/mpeg")
        #expect(upload.voice == Voice(duration: 1.5, waveform: [3, 4]) && upload.uploadToken != nil)
        #expect(await fake.sentDrafts.last?.text == "")
    }
}

struct WaveformTests {
    @Test func barsKeepEachBucketsPeak() {
        #expect(Waveform.bars([1, 9, 2, 3, 8, 4], count: 3) == [9, 3, 8])
        #expect(Waveform.bars([5, 7], count: 4) == [5, 5, 7, 7])   // stretched
        #expect(Waveform.bars(Array(0..<100), count: 10).count == 10)
        #expect(Waveform.bars(Array(0..<100), count: 10).last == 99)
        #expect(Waveform.bars([], count: 5).isEmpty && Waveform.bars([1], count: 0).isEmpty)
    }
    @Test func metersMapToZeroToHundred() {
        #expect(Waveform.level(decibels: 0) == 100)
        #expect(Waveform.level(decibels: -160) == 0)
        #expect(Waveform.level(decibels: -6) == 50)
        #expect(Waveform.level(decibels: 3) == 100)
    }
    @Test func levelsComeFromTheAudioWhenNoneWereSent() throws {
        // 0.3 s at 8 kHz: silence, full scale, half scale.
        let samples = [Int16](repeating: 0, count: 800) + [Int16](repeating: .max, count: 800) + [Int16](repeating: 16_384, count: 800)
        let levels = try #require(Waveform.levels(ofAudio: FakeBackend.wav(samples)))
        #expect(levels == [0, 100, 50])
        #expect(Waveform.levels(ofAudio: Data("not audio".utf8)) == nil)
    }
    @Test func timesReadAsMinutesAndSeconds() {
        #expect(Waveform.time(0) == "0:00" && Waveform.time(7.9) == "0:07" && Waveform.time(65) == "1:05")
    }
}

struct VoiceLayoutTests {
    private func row(_ voice: Voice) -> TimelineRow {
        RowLayoutTests.row("") { $0.attachments = [Attachment(name: "UserRecording_1.m4a", contentType: "audio/mpeg", kind: .voice, voice: voice)] }
    }
    @Test func aVoiceRowReservesItsPlayerAndGrowsWithLengthAndTranscript() throws {
        let short = RowLayout.make(row(Voice(duration: 2)), width: 700, own: false, kind: .direct)
        let long = RowLayout.make(row(Voice(duration: 40)), width: 700, own: false, kind: .direct)
        let transcribed = RowLayout.make(row(Voice(duration: 2, transcript: "A transcript long enough to wrap onto a second line in the bubble")), width: 700, own: false, kind: .direct)
        let frame = try #require(short.attachments.first)
        #expect(frame.size == VoiceLayout.size(Voice(duration: 2), maxWidth: .greatestFiniteMagnitude))
        #expect(frame.height == VoiceLayout.height && frame.width >= VoiceLayout.button + VoiceLayout.gap + 110)
        #expect(try #require(long.attachments.first).width > frame.width)
        #expect(try #require(long.attachments.first).width <= VoiceLayout.button + VoiceLayout.gap + 200)
        #expect(try #require(transcribed.attachments.first).height > frame.height && transcribed.height > short.height)
        for layout in [short, long, transcribed] { #expect(layout.bubble.contains(try #require(layout.attachments.first))) }
    }
    @Test func aNarrowBubbleNarrowsTheWaveform() throws {
        let narrow = RowLayout.make(row(Voice(duration: 40)), width: 260, own: true, kind: .direct)
        let frame = try #require(narrow.attachments.first)
        #expect(narrow.bubble.contains(frame) && frame.width <= narrow.bubble.width)
    }
}

@MainActor @Suite(.serialized) struct VoicePlaybackTests {
    private let silence = FakeBackend.wav([Int16](repeating: 0, count: 8_000))   // 1 s
    @Test func onlyOneMessagePlaysAtATime() throws {
        let playback = VoicePlayback()
        try playback.play("a", data: silence)
        #expect(playback.current == "a" && playback.isPlaying && abs(playback.duration - 1) < 0.01)
        try playback.play("b", data: silence, at: 0.5)
        #expect(playback.current == "b" && playback.isPlaying && abs(playback.elapsed - 0.5) < 0.05)
        playback.stop()
        #expect(playback.current == nil && !playback.isPlaying)
    }
    @Test func toggleSeekAndSpeed() async throws {
        let playback = VoicePlayback()
        try playback.play("a", data: silence)
        await playback.toggle("a") { Data() }
        #expect(playback.current == "a" && !playback.isPlaying)
        await playback.seek("a", to: 0.25) { Data() }
        #expect(abs(playback.elapsed - 0.25) < 0.05 && abs(playback.progress - 0.25) < 0.05)
        await playback.toggle("a") { Data() }
        #expect(playback.isPlaying)
        #expect(playback.rate == 1)
        playback.cycleRate(); #expect(playback.rate == 1.5)
        playback.cycleRate(); #expect(playback.rate == 2)
        playback.cycleRate(); #expect(playback.rate == 1)
        // Another message starts from its loaded bytes and stops this one.
        let silence = silence
        await playback.toggle("b") { silence }
        #expect(playback.current == "b" && playback.isPlaying)
        // Bytes that aren't audio leave nothing playing.
        await playback.toggle("c") { Data("nope".utf8) }
        #expect(playback.current == nil && !playback.isPlaying)
        playback.stop()
    }
}

/// A voice message's transcript, as Google Chat shows it: one line and "View transcript", or all of it and "Hide transcript".
@MainActor struct TranscriptToggleTests {
    private let long = String(repeating: "So, like I say, I just wanted to see what is working and what is not working. ", count: 4)
    private func row(open: Bool) -> TimelineRow {
        var message = Message(id: "v", conversationID: "c", sender: Person(id: "me", name: "Me"), text: "")
        message.attachments = [Attachment(name: "UserRecording_1.m4a", contentType: "audio/mpeg", kind: .voice, voice: Voice(duration: 11, transcript: long))]
        return TimelineRow.rows([message], transcripts: open ? ["v"] : [])[0]
    }
    @Test func aTranscriptOpensToAllOfItAndClosesToOneLine() {
        let closed = RowLayout.make(row(open: false), width: 600, own: true, kind: .direct)
        let open = RowLayout.make(row(open: true), width: 600, own: true, kind: .direct)
        let oneLine = RowLayout.measure(VoiceLayout.transcriptText("x"), width: 300).height
        #expect(row(open: true).transcriptOpen && !row(open: false).transcriptOpen)
        #expect(closed.attachments[0].height <= VoiceLayout.height + 4 + oneLine + 1)
        #expect(open.attachments[0].height > closed.attachments[0].height + 2 * oneLine)
    }
    @Test func theStoreRemembersWhichTranscriptsAreOpen() {
        let store = ChatStore(backend: FakeBackend())
        store.toggleTranscript("v")
        #expect(store.openTranscripts == ["v"])
        store.toggleTranscript("v")
        #expect(store.openTranscripts.isEmpty)
    }
}
