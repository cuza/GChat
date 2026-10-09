import Foundation

enum WebChannelError: Error, Equatable { case malformed, stopped }

/// Closure WebChannel v8 wire format, as Google Chat's realtime channel serves it.
enum WebChannelWire {
    /// `json`: an array payload (the Punctual channel's PBLite), re-serialized.
    enum Payload: Equatable { case json(Data), noop, stop, close, handshake(sid: String, keepaliveMs: Int), other }
    struct Frame: Equatable { var aid: Int; var payload: Payload }
    struct Handshake: Equatable { var sid: String; var keepaliveMs: Int }

    /// Removes complete `<length>\n<json>` frames from the front of `buffer`. Lengths count UTF-16 units (Closure strings).
    static func takeFrames(_ buffer: inout [UInt8]) throws -> [Frame] {
        var frames: [Frame] = []
        var start = 0
        while true {
            var i = start
            while i < buffer.count, [9, 10, 13, 32].contains(buffer[i]) { i += 1 }
            guard let newline = buffer[i...].firstIndex(of: 10) else { break }
            guard let units = Int(String(decoding: buffer[i..<newline], as: UTF8.self)), units >= 0 else { throw WebChannelError.malformed }
            guard let end = end(of: buffer, from: newline + 1, units: units) else { break }
            frames += try parse(Data(buffer[(newline + 1)..<end]))
            start = end
        }
        buffer.removeFirst(start)
        return frames
    }

    /// Accumulates streamed bytes and yields frames as soon as they are complete.
    struct FrameReader {
        private var buffer: [UInt8] = []
        mutating func feed(_ byte: UInt8) throws -> [Frame] {
            buffer.append(byte)
            // A frame ends with its JSON's "]", or with a newline when the length counts one.
            guard byte == UInt8(ascii: "]") || byte == 10 else { return [] }
            return try takeFrames(&buffer)
        }
    }

    static func handshake(body: [UInt8]) -> Handshake? {
        var candidates: [[Frame]] = []
        var prefixed = body
        candidates.append((try? takeFrames(&prefixed)) ?? [])
        candidates.append((try? parse(Data(body))) ?? [])
        for frames in candidates {
            for frame in frames { if case .handshake(let sid, let keepalive) = frame.payload { return Handshake(sid: sid, keepaliveMs: keepalive) } }
        }
        return nil
    }

    /// Byte offset after `units` UTF-16 units starting at `from`, or nil if the buffer is too short.
    private static func end(of bytes: [UInt8], from: Int, units: Int) -> Int? {
        var index = from, counted = 0
        while counted < units {
            guard index < bytes.count else { return nil }
            let lead = bytes[index]
            let width = lead < 0x80 ? 1 : lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : 2
            counted += width == 4 ? 2 : 1
            index += width
        }
        return index <= bytes.count ? index : nil
    }

    private static func parse(_ json: Data) throws -> [Frame] {
        guard let outer = try JSONSerialization.jsonObject(with: json) as? [Any] else { throw WebChannelError.malformed }
        return outer.compactMap { element in
            guard let pair = element as? [Any], pair.count >= 2, let aid = pair[0] as? Int, let body = pair[1] as? [Any] else { return nil }
            return Frame(aid: aid, payload: payload(body))
        }
    }
    private static func payload(_ body: [Any]) -> Payload {
        if let tag = body.first as? String {
            switch tag {
            case "noop": return .noop
            case "stop": return .stop
            case "close": return .close
            case "c":
                guard body.count > 1, let sid = body[1] as? String, !sid.isEmpty else { return .other }
                return .handshake(sid: sid, keepaliveMs: body.count > 5 ? (body[5] as? Int ?? 30_000) : 30_000)
            default: return .other
            }
        }
        if body.first is [Any], let json = try? JSONSerialization.data(withJSONObject: body) { return .json(json) }
        return .other
    }
}
