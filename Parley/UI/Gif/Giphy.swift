import Foundation
import Security

/// GIPHY search and trending (developers.giphy.com/docs/api/endpoint). The key is the user's own, from the Keychain.
enum Giphy {
    struct Rendition: Hashable, Sendable { var url: URL; var width: Int; var height: Int }
    struct Gif: Identifiable, Hashable, Sendable {
        var id: String
        var title: String
        var preview: Rendition    // images.fixed_width: small, for the grid
        var original: Rendition   // images.original: what gets sent
        /// What a message carries: recipients load the original .gif from GIPHY's CDN.
        var attachment: Attachment {
            Attachment(name: title, contentType: "image/gif", kind: .image, thumbnailURL: original.url, url: original.url,
                       width: original.width, height: original.height)
        }
    }
    enum Failure: Error, Equatable, LocalizedError {
        case rateLimited, http(Int)
        var errorDescription: String? {
            switch self {
            case .rateLimited: "GIPHY rate limit (100/hour on a beta key). Try again later."
            case .http(let status): "GIPHY answered \(status). Check the API key in Settings."
            }
        }
    }

    /// The user's API key: a generic password under its own Keychain service, never in defaults or the repo.
    static let keyItem = KeychainPassword(service: "dev.cuza.Parley.giphy", account: "api-key")
    static var key: String? { try? keyItem.get() }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    /// Trending when `query` is blank, else search. ponytail: first page only (25); page with `offset` if that runs short.
    static func gifs(matching query: String, key: String, session: URLSession = Giphy.session) async throws -> [Gif] {
        let query = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(50))   // GIPHY caps q at 50 chars
        var parts = URLComponents(string: "https://api.giphy.com/v1/gifs/\(query.isEmpty ? "trending" : "search")")!
        parts.queryItems = [URLQueryItem(name: "api_key", value: key)] + (query.isEmpty ? [] : [URLQueryItem(name: "q", value: query)])
            + [URLQueryItem(name: "limit", value: "25"), URLQueryItem(name: "rating", value: "pg-13")]
        let (data, response) = try await session.data(from: parts.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 { throw Failure.rateLimited }
        guard status == 200 else { throw Failure.http(status) }
        return try JSONDecoder().decode(Page.self, from: data).data.compactMap(\.gif)
    }

    // GIPHY's wire shape: renditions give width and height as strings.
    private struct Page: Decodable { var data: [Item] }
    private struct Item: Decodable {
        var id: String
        var title: String?
        var images: [String: Wire]?
        struct Wire: Decodable { var url: String?; var width: String?; var height: String? }
        var gif: Gif? {
            func rendition(_ name: String) -> Rendition? {
                guard let wire = images?[name], let url = wire.url.flatMap(URL.init(string:)), url.scheme == "https",
                      let width = wire.width.flatMap(Int.init), let height = wire.height.flatMap(Int.init) else { return nil }
                return Rendition(url: url, width: width, height: height)
            }
            guard let preview = rendition("fixed_width"), let original = rendition("original") else { return nil }
            return Gif(id: id, title: title ?? "", preview: preview, original: original)
        }
    }
}

/// One generic-password Keychain item, kept apart from the sign-in session's items.
struct KeychainPassword {
    let service: String, account: String
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }
    func get() throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
    }
    /// Empty or nil removes the item.
    func set(_ value: String?) throws {
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        let status = SecItemAdd(query.merging([kSecValueData as String: Data(value.utf8)]) { $1 } as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
