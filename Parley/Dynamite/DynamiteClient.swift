import Foundation
import SwiftProtobuf

enum DynamiteError: Error, LocalizedError, Equatable {
    case notYetSupported(String), badID, joinRefused, leaveRefused
    var errorDescription: String? {
        switch self {
        case .joinRefused: "Google Chat didn’t let you join that space."
        case .leaveRefused: "Google Chat didn’t let you leave that conversation."
        case .notYetSupported(let feature): "\(feature) isn’t available with Google Chat yet."
        case .badID: "That isn’t a Google Chat conversation or message ID."
        }
    }
}

/// Binary protobuf RPCs over the author's web session. `rt=b` is the live-verified response format.
struct DynamiteClient: Sendable {
    let authorizer: WebSessionAuthorizer
    /// As the web client, whose session this is: for the mobile client types Google leaves out what only web renders,
    /// such as a group DM's name and a forwarded message's card (quoted_message_metadata).
    static var header: Dynamite_RequestHeader {
        .with { $0.traceID = 0; $0.clientType = .web; $0.clientFeatureCapabilities = capabilities }
    }
    /// The capability fields Google Chat's web client declares, each FULLY_SUPPORTED (2). The whole list, on every RPC:
    /// declaring any list switches off what it leaves out (17 alone dropped forwards, group DM names and Ask Gemini), while
    /// 17 is what opens the history of some personal-account DMs.
    static let webCapabilities = [5, 6, 8, 9, 10, 11, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 32, 33, 37, 38,
                                  43, 44, 45, 46, 48, 51, 53, 54, 55, 56, 58, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 72, 73]
    /// Built from the wire form: only the fields Parley acts on are named in the proto; the rest travel as they are.
    static let capabilities: Dynamite_ClientFeatureCapabilities = {
        var bytes: [UInt8] = []
        for field in webCapabilities {
            var key = UInt64(field) << 3
            while key >= 0x80 { bytes.append(UInt8(key & 0x7F) | 0x80); key >>= 7 }
            bytes.append(UInt8(key)); bytes.append(2)
        }
        return (try? Dynamite_ClientFeatureCapabilities(serializedBytes: Data(bytes))) ?? .init()
    }()

    func call<Response: SwiftProtobuf.Message>(_ method: String, _ request: some SwiftProtobuf.Message) async throws -> Response {
        var urlRequest = URLRequest(url: URL(string: "https://chat.google.com/api/\(method)?rt=b")!)
        urlRequest.httpMethod = "POST"
        let body: Data = try request.serializedBytes()
        urlRequest.httpBody = body
        urlRequest.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")
        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try await authorizer.data(for: urlRequest) }
        catch let error as URLError where error.code == .networkConnectionLost {
            // URLSession reused a keep-alive connection the server had closed; retry once on a fresh one. Safe for
            // sends too: their ids are client-made, so Google refuses a repeat instead of posting it twice.
            (data, response) = try await authorizer.data(for: urlRequest)
        }
        do { return try Response(serializedBytes: DynamiteReadProbe.responseBytes(data, response: response)) }
        catch is BinaryDecodingError { throw AuthFailure.malformedProto }
    }
}
