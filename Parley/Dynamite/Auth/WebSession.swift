import CryptoKit
import Foundation
import OSLog
import Security

enum AuthFailure: Error, LocalizedError, Equatable {
    case signInRequired, browserClosed, chatNotOpen
    case invalidSession, invalidDestination, unexpectedResponse, malformedProto
    case http(Int), keychain(OSStatus)
    case bootstrapRejected(Int), bootstrapRedirect(String), bootstrapTokenMissing
    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to Google Chat again."
        case .browserClosed: "The sign-in window was closed. Start a new sign-in."
        case .chatNotOpen: "Finish signing in until Google Chat opens, then try again."
        case .invalidSession: "The sign-in has no usable Google Chat credentials. Finish signing in and try again."
        case .invalidDestination: "Refused to send credentials outside Google Chat."
        case .unexpectedResponse: "Google returned an unexpected response format. The auth check has not passed."
        case .malformedProto: "Google’s response did not match the expected protobuf schema."
        case .bootstrapRejected(let status): "Web bootstrap rejected the imported session (HTTP \(status))."
        case .bootstrapRedirect(let destination): "Web bootstrap redirected to \(destination). No credentials were forwarded."
        case .bootstrapTokenMissing: "Web bootstrap returned HTTP 200 but no XSRF token. The shell request or response format may have changed."
        case .http(let status): "Google Chat returned HTTP \(status)."
        case .keychain(let status): "Keychain operation failed (\(status))."
        }
    }
    static let signInCategory = "Google sign-in"
    /// Google itself refused the session or sent it to sign in: it is dead. Anything else (a proxy, a portal, a
    /// protocol change) keeps it for diagnosis and a later retry.
    var endsSession: Bool {
        switch self {
        case .signInRequired, .bootstrapRejected: true
        case .bootstrapRedirect(let destination): destination == Self.signInCategory
        default: false
        }
    }
}

struct SessionCookie: Codable, Equatable, Sendable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var secure: Bool
    var expires: Double

    func applies(to url: URL, now: Date = .now) -> Bool {
        guard let host = url.host?.lowercased(), !name.isEmpty, !value.isEmpty,
              !name.contains(where: { $0.isWhitespace || "=;\r\n".contains($0) }),
              !value.contains(where: { ";\r\n".contains($0) }),
              expires <= 0 || expires > now.timeIntervalSince1970,
              !secure || url.scheme == "https" else { return false }
        let domain = domain.lowercased()
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        guard bare == "google.com" || bare == "chat.google.com" else { return false }
        guard host == bare || (domain.hasPrefix(".") && host.hasSuffix("." + bare)) else { return false }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let cookiePath = path.isEmpty ? "/" : path
        return requestPath == cookiePath || (requestPath.hasPrefix(cookiePath) && (cookiePath.hasSuffix("/") || requestPath.dropFirst(cookiePath.count).first == "/"))
    }
    static func header(_ cookies: [Self], for url: URL, now: Date = .now) -> String {
        cookies.filter { $0.applies(to: url, now: now) }
            .sorted { $0.path.count == $1.path.count ? $0.name < $1.name : $0.path.count > $1.path.count }
            .map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
    /// Applies a response's `Set-Cookie` headers the way a browser jar would: same name, domain and path is
    /// updated in place, an expired one is removed, a new one is appended. Domains other than google.com and
    /// chat.google.com are never stored.
    static func merging(_ cookies: [Self], from response: HTTPURLResponse) -> [Self] {
        guard let url = response.url, response.value(forHTTPHeaderField: "Set-Cookie") != nil,
              let fields = response.allHeaderFields as? [String: String] else { return cookies }
        var merged = cookies
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
            let domain = cookie.domain.lowercased()
            guard [".google.com", "chat.google.com", ".chat.google.com"].contains(domain) else { continue }
            let index = merged.firstIndex { $0.name == cookie.name && $0.domain.lowercased() == domain && $0.path == cookie.path }
            // Max-Age=0 parses as an expiry of "now", so allow a second of slack.
            if let expiry = cookie.expiresDate, expiry.timeIntervalSinceNow < 1 {
                if let index { merged.remove(at: index) }
                continue
            }
            let updated = SessionCookie(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                                        secure: cookie.isSecure, expires: cookie.expiresDate?.timeIntervalSince1970 ?? -1)
            if let index {
                // A Max-Age cookie re-sent with the same value only slides its expiry; skip that so it is not a Keychain write per response.
                let current = merged[index]
                if current.value == updated.value, current.secure == updated.secure, current.expires > 0,
                   abs(current.expires - updated.expires) < 86_400 { continue }
                merged[index] = updated
            } else { merged.append(updated) }
        }
        return merged
    }
}

struct WebCredentials: Codable, Sendable {
    var cookies: [SessionCookie]
    var userAgent: String
}

protocol SessionVault: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func delete() throws
}
struct KeychainSessionVault: SessionVault {
    // Xcode's Debug builds keep their own session: an entry saved by one signature locks the other build out of it,
    // so a Debug build and the installed app running side by side would keep signing each other out.
    #if DEBUG
    var service = "dev.cuza.Parley.debug"
    #else
    var service = "dev.cuza.Parley"
    #endif
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "dynamite.web-session"]
    }
    func read() throws -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AuthFailure.keychain(status) }
        return result as? Data
    }
    func write(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw AuthFailure.keychain(added) }
        } else if status != errSecSuccess { throw AuthFailure.keychain(status) }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AuthFailure.keychain(status) }
    }
}

/// Never follows redirects with manually attached cookies. No shared browser cookie jar.
final class NoAuthRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor WebSessionAuthorizer {
    static let worldURL = URL(string: "https://chat.google.com/mole/world")!
    static var bootstrapURL: URL {
        var url = URLComponents(url: worldURL, resolvingAgainstBaseURL: false)!
        // Protocol inputs observed in the reference's Gmail Chat-shell bootstrap.
        // The historical shell descriptor is intentional; compatibility must be proved live.
        let descriptor = #"["h_hs",null,null,[1,0],null,null,"gmail.pinto-server_20230730.06_p0",1,null,[15,38,36,35,26,30,41,18,24,11,21,14,6],null,null,"3Mu86PSulM4.en..es5",0,null,null,[0]]"#
        url.queryItems = ["origin": "https://mail.google.com", "shell": "9", "hl": "en", "wfi": "gtn-roster-iframe-id", "hs": descriptor]
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }
    private let vault: any SessionVault
    private let session: URLSession
    private var xsrf: String?
    private var generation = 0
    private var punctualBlock: String?   // the realtime registration from the last bootstrap page
    init(vault: any SessionVault = KeychainSessionVault(), session: URLSession? = nil) {
        self.vault = vault
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCache = nil
            config.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: config, delegate: NoAuthRedirects(), delegateQueue: nil)
        }
    }
    static func extractXSRF(_ page: String) -> String? {
        // Accept JSON escapes and optional whitespace, without printing the HTML.
        let pattern = #""SMqcke"\s*:\s*("(?:[^"\\]|\\.)*")"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: page, range: NSRange(page.startIndex..., in: page)),
              let range = Range(match.range(at: 1), in: page),
              let array = try? JSONSerialization.jsonObject(with: Data("[\(page[range])]".utf8)) as? [String],
              let token = array.first, !token.isEmpty, !token.contains(where: { $0 == "\r" || $0 == "\n" }) else { return nil }
        return token
    }
    static func validateDestination(_ url: URL?) throws {
        guard let url, url.scheme == "https", url.host == "chat.google.com",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil else { throw AuthFailure.invalidDestination }
    }
    func signIn(cookies: [SessionCookie], userAgent: String) async throws {
        generation += 1
        let current = generation
        let usable = cookies.filter { $0.applies(to: Self.worldURL) }
        guard !usable.isEmpty else { throw AuthFailure.invalidSession }
        guard !userAgent.isEmpty, userAgent.count <= 1024, !userAgent.contains(where: { $0 == "\r" || $0 == "\n" }) else { throw AuthFailure.invalidSession }
        var credentials = WebCredentials(cookies: cookies, userAgent: userAgent)
        let (token, bootstrap) = try await fetchXSRF(credentials)
        guard current == generation else { throw CancellationError() }
        try Task.checkCancellation()
        credentials.cookies = SessionCookie.merging(credentials.cookies, from: bootstrap)
        try vault.write(JSONEncoder().encode(credentials))
        xsrf = token
    }
    func signOut() throws {
        generation += 1
        xsrf = nil
        try vault.delete()
    }
    private func storedCredentials() throws -> WebCredentials {
        guard let data = try vault.read() else { throw AuthFailure.signInRequired }
        if let credentials = try? JSONDecoder().decode(WebCredentials.self, from: data), !credentials.cookies.isEmpty {
            return credentials
        }
        try signOut(); throw AuthFailure.signInRequired
    }
    /// Saves the response's cookie updates into the stored session, writing only when something changed.
    /// Skipped once the session was signed out or replaced, so a late response cannot bring it back.
    private func saveCookies(from response: HTTPURLResponse, generation current: Int) {
        guard current == generation, response.value(forHTTPHeaderField: "Set-Cookie") != nil,
              var credentials = try? storedCredentials() else { return }
        let merged = SessionCookie.merging(credentials.cookies, from: response)
        guard merged != credentials.cookies else { return }
        credentials.cookies = merged
        try? vault.write(JSONEncoder().encode(credentials))
    }
    private func fetchXSRF(_ credentials: WebCredentials) async throws -> (String, HTTPURLResponse) {
        var request = URLRequest(url: Self.bootstrapURL)
        let header = SessionCookie.header(credentials.cookies, for: Self.bootstrapURL)
        guard !header.isEmpty else { throw AuthFailure.signInRequired }
        request.setValue(header, forHTTPHeaderField: "Cookie")
        request.setValue(credentials.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://mail.google.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AuthFailure.unexpectedResponse }
        if (300..<400).contains(response.statusCode) {
            let location = response.value(forHTTPHeaderField: "Location") ?? ""
            let host = URL(string: location, relativeTo: Self.bootstrapURL)?.host
            // Fixed categories only: never log redirect URLs or query parameters.
            let category = host == "accounts.google.com" ? AuthFailure.signInCategory : host == "chat.google.com" ? "another Google Chat page" : "an unexpected destination"
            throw AuthFailure.bootstrapRedirect(category)
        }
        if response.statusCode == 401 || response.statusCode == 403 { throw AuthFailure.bootstrapRejected(response.statusCode) }
        guard response.statusCode == 200 else { throw AuthFailure.http(response.statusCode) }
        let page = String(decoding: data, as: UTF8.self)
        guard let token = Self.extractXSRF(page) else { throw AuthFailure.bootstrapTokenMissing }
        punctualBlock = PunctualWire.registrationBlock(in: page)
        return (token, response)
    }
    /// The realtime (Punctual) registration from the bootstrap page, as JSON; `fresh` loads the page again.
    func punctualRegistration(fresh: Bool = false) async throws -> String? {
        guard fresh || punctualBlock == nil else { return punctualBlock }
        let current = generation
        do {
            let (token, bootstrap) = try await fetchXSRF(try storedCredentials())
            guard current == generation else { throw CancellationError() }
            xsrf = token
            saveCookies(from: bootstrap, generation: current)
        } catch let failure as AuthFailure where failure.endsSession && current == generation {
            try signOut(); throw failure
        }
        return punctualBlock
    }
    /// `Authorization` for Google's cookie-authenticated APIs: `SAPISIDHASH <ts>_<sha1("<ts> <SAPISID> <origin>")>`.
    static func sapisidHash(_ cookies: [SessionCookie], at date: Date = .now, origin: String = "https://chat.google.com") -> String? {
        guard let sapisid = (cookies.first { $0.name == "SAPISID" } ?? cookies.first { $0.name == "__Secure-3PAPISID" })?.value,
              !sapisid.isEmpty else { return nil }
        let seconds = Int(date.timeIntervalSince1970)
        let digest = Insecure.SHA1.hash(data: Data("\(seconds) \(sapisid) \(origin)".utf8)).map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(seconds)_\(digest)"
    }
    /// Auth failures get one fresh bootstrap and retry. A second failure clears the session only when Google answers
    /// with its sign-in page; otherwise the fresh bootstrap proved the session alive and the status is thrown as `.http`.
    func data(for original: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await perform(original, { [session] in try await session.data(for: $0) },
                          text: { String(decoding: $0, as: UTF8.self) })
    }
    /// Streaming variant for the realtime channel: same checks, credentials and retry as `data(for:)`; returns once headers arrive.
    func bytes(for original: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        try await perform(original, { [session] in try await session.bytes(for: $0) }, text: { bytes in
            var data = Data()
            do { for try await byte in bytes { data.append(byte); if data.count >= 1 << 20 { break } } } catch {}
            return String(decoding: data, as: UTF8.self)
        })
    }
    /// Why Google refused a request, for the log: the readable runs of its error body (its status names the problem),
    /// without addresses or cookie values, at most 300 characters.
    nonisolated static func reason(_ body: Data) -> String {
        let runs = String(decoding: body, as: UTF8.self).split { !$0.isASCII || $0.isNewline || ($0.asciiValue ?? 0) < 32 }
        let text = runs.filter { $0.count >= 6 }.joined(separator: " ")
        return String(ConnectionDiagnostics.redact(text).prefix(300))
    }
    /// Google's sign-in page served in place of the requested resource: a redirect to accounts.google.com,
    /// or the page itself, which names the `AccountsSignInUi` app in its global data.
    static func isSignInPage(_ response: HTTPURLResponse, body: String) -> Bool {
        if let location = response.value(forHTTPHeaderField: "Location"),
           URL(string: location, relativeTo: response.url)?.host?.lowercased() == "accounts.google.com" { return true }
        return body.range(of: #"qwAQke\\?"\s*:\s*\\?"AccountsSignInUi"#, options: .regularExpression) != nil
    }
    private func perform<Body: Sendable>(_ original: URLRequest,
                                         _ transport: @Sendable (URLRequest) async throws -> (Body, URLResponse),
                                         text: @Sendable (Body) async -> String) async throws -> (Body, HTTPURLResponse) {
        try Self.validateDestination(original.url)
        let current = generation
        do {
            for attempt in 0...1 {
                if xsrf == nil {
                    let (token, bootstrap) = try await fetchXSRF(try storedCredentials())
                    guard current == generation else { throw CancellationError() }
                    xsrf = token
                    saveCookies(from: bootstrap, generation: current)
                }
                guard current == generation else { throw CancellationError() }
                try Task.checkCancellation()
                // Read per attempt so a retry carries cookies the failed reply or the bootstrap just updated.
                let credentials = try storedCredentials()
                var request = original
                let header = SessionCookie.header(credentials.cookies, for: original.url!)
                guard !header.isEmpty else { throw AuthFailure.signInRequired }
                request.setValue(header, forHTTPHeaderField: "Cookie")
                request.setValue(credentials.userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue(xsrf, forHTTPHeaderField: "X-Framework-XSRF-Token")
                request.setValue("https://chat.google.com", forHTTPHeaderField: "Origin")
                request.setValue("https://chat.google.com/", forHTTPHeaderField: "Referer")
                // The realtime channel also wants the SAPISID hash, as Google Chat sends it there.
                if original.url!.path.hasPrefix("/punctual/"), let hash = Self.sapisidHash(credentials.cookies) {
                    request.setValue(hash, forHTTPHeaderField: "Authorization")
                    request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
                }
                let (body, response) = try await transport(request)
                guard current == generation else { throw CancellationError() }
                guard let response = response as? HTTPURLResponse else { throw AuthFailure.unexpectedResponse }
                saveCookies(from: response, generation: current)
                if response.statusCode == 401 || response.statusCode == 403 {
                    xsrf = nil
                    if attempt == 0 { continue }
                    let page = await text(body)
                    if Self.isSignInPage(response, body: page) { throw AuthFailure.signInRequired }
                    authLog.error("\(original.url?.path ?? "?", privacy: .public) refused (\(response.statusCode, privacy: .public)): \(Self.reason(Data(page.utf8)), privacy: .public)")
                    throw AuthFailure.http(response.statusCode)
                }
                if (300..<400).contains(response.statusCode) {   // a proxy or captive-portal redirect is not a sign-out
                    throw Self.isSignInPage(response, body: "") ? AuthFailure.signInRequired : AuthFailure.http(response.statusCode)
                }
                guard response.statusCode == 200 else {
                    let reason = Self.reason(Data(await text(body).utf8))
                    authLog.error("\(original.url?.path ?? "?", privacy: .public) refused (\(response.statusCode, privacy: .public)): \(reason, privacy: .public)")
                    throw AuthFailure.http(response.statusCode)
                }
                return (body, response)
            }
            throw AuthFailure.signInRequired
        } catch let failure as AuthFailure {
            if failure.endsSession, current == generation {
                // Only the request that ended a stored session: path only, no query string.
                if (try? vault.read()) != nil {
                    authLog.notice("Google ended the session at \(original.url?.path ?? "?", privacy: .public): \(String(describing: failure), privacy: .public)")
                }
                try signOut()
            }
            throw failure
        }
    }
}
