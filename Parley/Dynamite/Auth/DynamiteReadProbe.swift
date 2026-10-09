import Foundation

/// A deliberately small wire reader for Connection Diagnostics' read check, independent of the protocol layer it
/// checks, so a broken mapper can't hide a working session. Field numbers follow Google Chat's schema.
enum ProbeWire {
    struct Field: Equatable {
        var number: Int
        var bytes: Data?
        var integer: UInt64?
    }
    static func varint(_ value: UInt64) -> Data {
        var value = value
        var data = Data()
        repeat {
            let byte = UInt8(value & 127)
            value >>= 7
            data.append(value == 0 ? byte : byte | 128)
        } while value != 0
        return data
    }
    static func integer(_ field: Int, _ value: UInt64) -> Data {
        varint(UInt64(field << 3)) + varint(value)
    }
    static func message(_ field: Int, _ bytes: Data) -> Data {
        varint(UInt64(field << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
    }
    static func string(_ field: Int, _ value: String) -> Data { message(field, Data(value.utf8)) }
    static var header: Data { integer(1, 0) + integer(2, 2) } // client type IOS
    static var identityRequest: Data { message(100, header) }
    static func worldRequest(cursors: [String] = []) -> Data {
        let sections = cursors.isEmpty ? [""] : cursors
        return sections.reduce(message(1, header)) { result, cursor in
            var section = integer(1, 200)
            if !cursor.isEmpty { section += string(6, cursor) }
            return result + message(2, section)
        } + integer(5, 1) + integer(7, 1)
    }
    static func fields(_ data: Data) throws -> [Field] {
        guard data.count <= 16 * 1024 * 1024 else { throw AuthFailure.malformedProto }
        let bytes = [UInt8](data)
        var index = 0
        func readVarint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in 0..<10 {
                guard index < bytes.count else { throw AuthFailure.malformedProto }
                let byte = bytes[index]; index += 1
                if shift == 9 && byte > 1 { throw AuthFailure.malformedProto }
                value |= UInt64(byte & 127) << (shift * 7)
                if byte & 128 == 0 { return value }
            }
            throw AuthFailure.malformedProto
        }
        func take(_ length: Int) throws -> Data {
            guard length >= 0, length <= bytes.count - index else { throw AuthFailure.malformedProto }
            let value = Data(bytes[index..<(index + length)]); index += length
            return value
        }
        var output: [Field] = []
        while index < bytes.count {
            let tag = try readVarint()
            let number = tag >> 3
            guard number > 0, number <= 536_870_911 else { throw AuthFailure.malformedProto }
            switch tag & 7 {
            case 0: output.append(Field(number: Int(number), integer: try readVarint()))
            case 1: _ = try take(8)
            case 2:
                let length = try readVarint()
                guard length <= UInt64(bytes.count - index) else { throw AuthFailure.malformedProto }
                output.append(Field(number: Int(number), bytes: try take(Int(length))))
            case 5: _ = try take(4)
            default: throw AuthFailure.malformedProto
            }
        }
        return output
    }
    static func nested(_ data: Data, _ field: Int) throws -> Data {
        guard let value = try fields(data).first(where: { $0.number == field })?.bytes else { throw AuthFailure.malformedProto }
        return value
    }
    static func identity(_ data: Data) throws -> String {
        let bytes = try nested(nested(nested(data, 1), 1), 1)
        guard let value = String(data: bytes, encoding: .utf8), !value.isEmpty else { throw AuthFailure.malformedProto }
        return value
    }
    struct WorldPage {
        var groupKeys: Set<String>
        var cursors: [String]
    }
    static func worldPage(_ data: Data) throws -> WorldPage {
        let root = try fields(data)
        var items = root.filter { $0.number == 4 }.compactMap(\.bytes)
        var cursors: [String] = []
        for section in root.filter({ $0.number == 1 }).compactMap(\.bytes) {
            let values = try fields(section)
            items += values.filter { $0.number == 2 }.compactMap(\.bytes)
            if values.first(where: { $0.number == 5 })?.integer == 1 {
                guard let token = values.first(where: { $0.number == 6 })?.bytes,
                      let string = String(data: token, encoding: .utf8), !string.isEmpty else { throw AuthFailure.malformedProto }
                cursors.append(string)
            }
        }
        var keys: Set<String> = []
        for item in items {
            let group = try fields(nested(item, 1))
            guard let field = group.first(where: { ($0.number == 1 || $0.number == 3) && $0.bytes != nil }),
                  let bytes = field.bytes,
                  let id = String(data: try nested(bytes, 1), encoding: .utf8), !id.isEmpty else { throw AuthFailure.malformedProto }
            keys.insert("\(field.number):\(id)")
        }
        return WorldPage(groupKeys: keys, cursors: cursors)
    }
}

struct ReadCheckResult: Sendable { var conversationCount: Int }
struct DynamiteReadProbe: Sendable {
    let authorizer: WebSessionAuthorizer
    func run() async throws -> ReadCheckResult {
        _ = try ProbeWire.identity(await call("get_self_user_status", body: ProbeWire.identityRequest))
        var keys: Set<String> = []
        var cursors: [String] = []
        var seen: Set<String> = []
        for _ in 0..<100 {
            let page = try ProbeWire.worldPage(await call("paginated_world", body: ProbeWire.worldRequest(cursors: cursors)))
            keys.formUnion(page.groupKeys)
            cursors = Array(Set(page.cursors)).sorted()
            if cursors.isEmpty { return ReadCheckResult(conversationCount: keys.count) }
            guard cursors.allSatisfy({ seen.insert($0).inserted }) else { throw AuthFailure.malformedProto }
        }
        throw AuthFailure.malformedProto
    }
    private func call(_ method: String, body: Data) async throws -> Data {
        let url = URL(string: "https://chat.google.com/api/\(method)?rt=b")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")
        let (data, response) = try await authorizer.data(for: request)
        return try Self.responseBytes(data, response: response)
    }
    static func responseBytes(_ data: Data, response: HTTPURLResponse) throws -> Data {
        let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard type.contains("protobuf") || type.contains("octet-stream") else { throw AuthFailure.unexpectedResponse }
        var body = data
        let prefix = Data([0x29, 0x5D, 0x7D, 0x27]) // Google's anti-XSSI prefix
        if body.starts(with: prefix) {
            body = Data(body.dropFirst(prefix.count))
            while body.first == 10 || body.first == 13 { body = Data(body.dropFirst()) }
        }
        if response.value(forHTTPHeaderField: "X-Goog-Safety-Encoding")?.lowercased() == "base64" {
            let compact = body.filter { ![9, 10, 13, 32].contains($0) }
            guard let decoded = Data(base64Encoded: compact) else { throw AuthFailure.unexpectedResponse }
            return decoded
        }
        return body
    }
}
