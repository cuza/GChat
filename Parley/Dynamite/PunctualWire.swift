import Foundation

/// Google Chat's realtime "Punctual" multi-watch channel: the registration from the bootstrap page, and the
/// JSON+protobuf (PBLite) messages that open and feed watches. Pure functions; `PunctualChannel` does the I/O.
enum PunctualWire {
    /// Where the user's event stream lives, as the Chat page carries it (`dfe.cr.rr`).
    struct Registration: Equatable, Sendable {
        var baseURL: URL
        var startMicros: Int64
        var leaseSeconds: Int
        var utid: String
        var apiKey: String

        init?(_ json: String) {
            guard let block = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any], block.count > 2,
                  let config = block[2] as? [Any], config.count > 5,
                  let project = config[1] as? [Any], project.count > 1, let path = project[1] as? String,
                  let start = config[2] as? [Any], let seconds = int(start.first),
                  let utid = config[4] as? String, !utid.isEmpty, let key = config[5] as? String, !key.isEmpty else { return nil }
            // "/punctual/prod-dynamite-prod-02-us/<project>" is served at chat.google.com/punctual/prod-02-us.
            let env = path.split(separator: "/").dropFirst().first.map(String.init) ?? ""
            guard env.hasPrefix("prod-dynamite-prod-"), env.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
                  let base = URL(string: "https://chat.google.com/punctual/" + env.dropFirst("prod-dynamite-".count)) else { return nil }
            baseURL = base
            startMicros = seconds * 1_000_000 + (start.count > 1 ? int(start[1]) ?? 0 : 0) / 1000
            leaseSeconds = Int(int((config[3] as? [Any])?.first) ?? 3600)
            self.utid = utid
            apiKey = key
        }
    }

    /// The `["dfe.cr.rr", …]` array in a Chat page, as JSON.
    static func registrationBlock(in page: String) -> String? {
        let bytes = Array(page.utf8)
        guard let tag = page.range(of: #""dfe.cr.rr""#) else { return nil }
        var start = page.utf8.distance(from: page.utf8.startIndex, to: tag.lowerBound) - 1
        while start >= 0, bytes[start] != UInt8(ascii: "[") { start -= 1 }
        guard start >= 0 else { return nil }
        var depth = 0, inString = false, escaped = false
        for index in start..<bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["): depth += 1
            case UInt8(ascii: "]"):
                depth -= 1
                if depth == 0 { return String(decoding: bytes[start...index], as: UTF8.self) }
            default: break
            }
        }
        return nil
    }

    // MARK: Client → server

    struct Watch: Equatable, Sendable {
        enum Target: Equatable, Sendable { case user(String), typing(String) }
        var id: Int
        var target: Target
        var start: Int64?   // µs; the user stream's resume point
        var resumed: Bool
        var reason: Int     // 1 new, 2 retry after an error, 3 re-sent after the channel dropped
    }

    private static func target(_ target: Watch.Target) -> [Any] {
        switch target {
        case .user(let utid): [["user-targeted-changes"], [NSNull(), 1], [[["userTargeted"], [utid], ["events"]]]]
        case .typing(let group): [["group-state-changes"], [1], [[["state"], ["group"], [group], ["typing"]]]]
        }
    }
    private static func json(_ value: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])) ?? Data("[]".utf8), as: UTF8.self)
    }

    static func chooseServer(_ watch: Watch) -> String {
        json([[NSNull(), NSNull(), NSNull(), [9, 5], NSNull(), target(watch.target)], NSNull(), NSNull(), 0, 0])
    }
    static func batch(_ watches: [Watch], streamType: Int) -> String {
        json([watches.map { watch -> [Any] in
            let spec: [Any] = [watch.start.map { $0 as Any } ?? NSNull(), NSNull(), NSNull(), [9, 5], NSNull(), target(watch.target),
                               NSNull(), watch.resumed ? 1 : 0, watch.reason]
            return [watch.id, spec, NSNull(), streamType]
        }])
    }
    static func cancel(_ ids: [Int]) -> String { json([ids.map { [$0, NSNull(), [Any]()] as [Any] }]) }

    /// Forward-channel body: `count=N&ofs=O&reqK___data__=<urlencoded JSON>`.
    static func forwardBody(_ maps: [String], offset: Int) -> Data {
        var parts = ["count=\(maps.count)", "ofs=\(offset)"]
        for (index, map) in maps.enumerated() { parts.append("req\(index)___data__=\(map.addingPercentEncoding(withAllowedCharacters: formSafe)!)") }
        return Data(parts.joined(separator: "&").utf8)
    }
    private static let formSafe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._*")

    // MARK: Server → client

    struct ChooseServerReply: Equatable, Sendable {
        var session: String
        var streamType: Int
        var delayMs: Int
        init(session: String, streamType: Int, delayMs: Int) { self.session = session; self.streamType = streamType; self.delayMs = delayMs }
        init?(_ data: Data) {
            guard let reply = try? JSONSerialization.jsonObject(with: data) as? [Any], let session = reply.first as? String, !session.isEmpty else { return nil }
            self.session = session
            streamType = reply.count > 1 ? Int(int(reply[1]) ?? 1) : 1
            delayMs = reply.count > 2 ? Int(int(reply[2]) ?? 0) : 0
        }
    }

    enum Update: Equatable, Sendable {
        case channel(String)                 // id for refreshCreds
        case started(watch: Int, at: Int64)
        case watermark(watch: Int, at: Int64)
        case change(watch: Int, payload: Data)
        case failed(watch: Int, code: Int)
        case close                           // the server asks for a new channel
    }

    /// One backchannel array's payload (a watch response batch), as JSON.
    static func updates(_ json: String) -> [Update] {
        guard let batch = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any] else { return [] }
        return updates(batch)
    }
    static func updates(_ batch: [Any]) -> [Update] {
        var result: [Update] = []
        for response in batch.first as? [Any] ?? [] {
            guard let response = response as? [Any], let watch = int(response.first).map(Int.init) else { continue }
            if response.count > 1, let change = response[1] as? [Any] {
                if let started = int((change.first as? [Any])?.first) { result.append(.started(watch: watch, at: started)) }
                if change.count > 1, let items = (change[1] as? [Any])?.first as? [Any] {
                    for case let item as [Any] in items where item.count > 1 {
                        if let base64 = item[1] as? String, let payload = Data(base64Encoded: base64) { result.append(.change(watch: watch, payload: payload)) }
                    }
                }
                if change.count > 2, let mark = int((change[2] as? [Any])?.first) { result.append(.watermark(watch: watch, at: mark)) }
            }
            if response.count > 2, let status = (response[2] as? [Any])?.first as? [Any], let code = int(status.first), code != 0 {
                result.append(.failed(watch: watch, code: Int(code)))
            }
        }
        if batch.count > 1, let status = batch[1] as? [Any], int(status.first) == 1 { result.append(.close) }
        if batch.count > 2, let channel = (batch[2] as? [Any])?.first as? String { result.append(.channel(channel)) }
        return result
    }

    /// PBLite int64s arrive as numbers or strings.
    static func int(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber: number.int64Value
        case let text as String: Int64(text)
        default: nil
        }
    }
}
