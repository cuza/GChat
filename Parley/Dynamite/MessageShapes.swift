import AppKit
import Foundation
import Synchronization
import UniformTypeIdentifiers

/// An anonymous record of the messages Parley doesn't fully draw (see `DynamiteMapper.undrawn`), which a user can
/// export from the Help menu and send: each message's protobuf field tree, read from its wire bytes, with no values.
/// A skeleton names field numbers and nesting; `N:v` is a varint, `N:f32`/`N:f64` a fixed number, `N:Lk` a run of k
/// bytes (text, ids, links), `N{…}` a nested message, `×k` k equal repeats. Varints keep their value (`N=v`) only at
/// `enumPaths`. Kept in memory for the launch.
enum MessageShapes {
    struct Entry: Codable, Hashable, Sendable {
        var fields: [String]   // what the guard found undrawn, e.g. "19.1=9"
        var skeleton: String   // the first such message's whole tree
        var count = 1          // messages seen with this gap
    }
    static let cap = 200
    /// Field paths whose varints are kinds, not data, and tell shapes apart: the message type, an annotation's type and
    /// chip rendering, a bot response's type. Small values only.
    static let enumPaths: Set<String> = ["28", "11.1", "11.20", "19.1"]

    struct Store: Sendable {
        private(set) var entries: [Entry] = []
        private var index: [String: Int] = [:]
        /// Counts the message under its gap: the undrawn fields and the shapes of the undrawn parts (`parts`, from
        /// `DynamiteMapper.undrawnParts`), lengths and repeat counts aside, not the rest of the message. A new gap adds
        /// an entry with the message's whole tree, unless the store is full. True when added.
        @discardableResult mutating func record(_ proto: Dynamite_Message, fields: [String], parts: [String] = []) -> Bool {
            let plain = parts.map { $0.replacingOccurrences(of: #":L\d+|×\d+"#, with: "", options: .regularExpression) }
            let key = fields.joined(separator: ",") + "|" + Set(plain).sorted().joined(separator: "|")
            if let at = index[key] { entries[at].count += 1; return false }
            guard entries.count < cap, let bytes: [UInt8] = try? proto.serializedBytes() else { return false }
            index[key] = entries.count
            entries.append(Entry(fields: fields, skeleton: MessageShapes.skeleton(bytes[...], path: []) ?? "?"))
            return true
        }
    }
    static let shared = Mutex(Store())

    static func logLine(_ fields: [String]) -> String {
        "a message has content Parley doesn't draw: fields \(fields.joined(separator: ", "))"
    }

    /// The tree of `bytes` as a protobuf message, or nil when they don't read as one.
    static func skeleton(_ bytes: ArraySlice<UInt8>, path: [Int]) -> String? {
        var reader = Reader(bytes: bytes), parts: [String] = []
        while !reader.done {
            guard let key = reader.varint(), key >> 3 > 0, key >> 3 < 1 << 29 else { return nil }
            let field = Int(key >> 3), here = path + [field], name = here.map(String.init).joined(separator: ".")
            switch key & 7 {
            case 0:
                guard let value = reader.varint() else { return nil }
                parts.append(enumPaths.contains(name) && value < 1000 ? "\(field)=\(value)" : "\(field):v")
            case 1: guard reader.skip(8) else { return nil }; parts.append("\(field):f64")
            case 5: guard reader.skip(4) else { return nil }; parts.append("\(field):f32")
            case 2:
                guard let length = reader.varint(), let body = reader.take(Int(length)) else { return nil }
                // Text first: printable UTF-8 is a leaf even if it would also read as a message, so a string's bytes
                // never turn into field numbers. ponytail: a nested message that is all printable bytes (a single string
                // field of 32+ characters) shows as a leaf; fine for telling shapes apart.
                if isText(body) { parts.append("\(field):L\(body.count)") }
                else if let inner = skeleton(body, path: here) { parts.append("\(field){\(inner)}") }
                else { parts.append("\(field):L\(body.count)") }
            default: return nil
            }
        }
        // Equal neighbours (a repeated field's like entries) fold into one with a count.
        var folded: [(String, Int)] = []
        for part in parts { if folded.last?.0 == part { folded[folded.count - 1].1 += 1 } else { folded.append((part, 1)) } }
        return folded.map { $1 > 1 ? "\($0)×\($1)" : $0 }.joined(separator: " ")
    }
    private static func isText(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard let string = String(bytes: bytes, encoding: .utf8) else { return false }
        return string.unicodeScalars.allSatisfy { $0.value >= 0x20 || $0 == "\n" || $0 == "\t" || $0 == "\r" }
    }
    private struct Reader {
        var bytes: ArraySlice<UInt8>
        var done: Bool { bytes.isEmpty }
        mutating func varint() -> UInt64? {
            var value: UInt64 = 0, shift: UInt64 = 0
            while let byte = bytes.popFirst() {
                guard shift < 64 else { return nil }
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
            guard count >= 0, count <= bytes.count else { return nil }
            defer { bytes = bytes.dropFirst(count) }
            return bytes.prefix(count)
        }
        mutating func skip(_ count: Int) -> Bool { take(count) != nil }
    }

    static func export(_ entries: [Entry], app: String, os: String, date: Date) -> Data {
        struct File: Encodable { var app: String; var macOS: String; var date: Date; var entries: [Entry] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(File(app: app, macOS: os, date: date, entries: entries))) ?? Data()
    }

    /// Help ▸ Export Unsupported Message Shapes…: a JSON file to send to the developer, or a note when there is none.
    @MainActor static func saveExport() {
        let entries = shared.withLock { $0.entries }
        guard !entries.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No unsupported message shapes"
            alert.informativeText = "Parley has drawn every message it loaded since it opened. Try again after one shows up wrong."
            alert.runModal()
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Parley message shapes \(Date.now.formatted(.iso8601.year().month().day())).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let info = Bundle.main.infoDictionary
        let app = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        do { try export(entries, app: app, os: ProcessInfo.processInfo.operatingSystemVersionString, date: .now).write(to: url) }
        catch { NSAlert(error: error).runModal() }
    }
}
