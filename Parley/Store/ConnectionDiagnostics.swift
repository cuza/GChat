import Foundation
import Observation
import OSLog
import SwiftUI

/// The Connection Diagnostics window's state: the saved session as the Keychain holds it (names, never values)
/// and the read-only checks against Google Chat.
@MainActor @Observable
final class ConnectionDiagnostics {
    struct Status: Equatable { var title: String; var color: Color }
    struct Indicator: Equatable { var title: String; var symbol: String; var color: Color }
    struct CookieRow: Equatable, Identifiable {
        var name: String
        var domain: String
        var expires: Date?   // nil: ends with the browser session
        var id: String { name + "@" + domain }
    }
    struct Check: Equatable, Identifiable {
        let id = UUID()
        var name: String
        var passed: Bool
        var duration: Duration
        var message: String
        var durationText: String { String(format: "%.2f s", Double(duration.components.attoseconds) / 1e18 + Double(duration.components.seconds)) }
    }

    /// nil until read, or when the Keychain couldn't be read.
    private(set) var stored: Bool?
    private(set) var vaultError: String?
    private(set) var cookies: [CookieRow] = []
    var checks: [Check] = []
    private(set) var running = false
    @ObservationIgnored private let vault: any SessionVault
    @ObservationIgnored private let probe: @Sendable () async throws -> ReadCheckResult

    init(vault: any SessionVault, probe: @escaping @Sendable () async throws -> ReadCheckResult) {
        self.vault = vault; self.probe = probe
    }
    /// The app's own authorizer, so a check that finds the session gone signs the app out too.
    convenience init(authorizer: WebSessionAuthorizer) {
        self.init(vault: KeychainSessionVault(), probe: { try await DynamiteReadProbe(authorizer: authorizer).run() })
    }

    var indicator: Indicator {
        switch stored {
        case true?: Indicator(title: "Saved", symbol: "checkmark.circle.fill", color: .green)
        case false?: Indicator(title: "Not saved", symbol: "xmark.circle", color: .secondary)
        case nil: Indicator(title: "Unknown", symbol: "questionmark.circle", color: .orange)
        }
    }
    var earliestExpiry: Date? { cookies.compactMap(\.expires).min() }

    nonisolated static func status(_ state: ConnectionState) -> Status {
        switch state {
        case .connected: Status(title: "Connected", color: .green)
        case .connecting: Status(title: "Connecting", color: .yellow)
        case .reconnecting: Status(title: "Reconnecting", color: .orange)
        case .offline: Status(title: "Offline", color: .gray)
        case .signedOut: Status(title: "Signed out", color: .red)
        }
    }

    /// Re-reads the Keychain entry. Only names, domains and expiry dates leave this function.
    func refresh() {
        do {
            let data = try vault.read()
            stored = data != nil; vaultError = nil
            cookies = data.map(Self.cookies(in:)) ?? []
        } catch {
            stored = nil; vaultError = error.localizedDescription; cookies = []
        }
    }
    private static func cookies(in data: Data) -> [CookieRow] {
        let decoded = (try? JSONDecoder().decode(WebCredentials.self, from: data).cookies) ?? []
        return decoded.map { CookieRow(name: $0.name, domain: $0.domain, expires: $0.expires > 0 ? Date(timeIntervalSince1970: $0.expires) : nil) }
            .sorted { ($0.name, $0.domain) < ($1.name, $1.domain) }
    }

    /// The saved session, then each read format; stops once Google says the session is gone.
    func runChecks() async {
        guard !running else { return }
        running = true
        defer { running = false }
        checks = []
        let clock = ContinuousClock()
        let start = clock.now
        refresh()
        checks.append(Check(name: "Saved session", passed: stored == true, duration: clock.now - start,
                            message: stored == true ? "\(cookies.count) cookies in Keychain" : vaultError ?? "No session saved"))
        guard stored == true else { return }
        let readStart = clock.now
        let result: Result<ReadCheckResult, Error>
        do { result = .success(try await probe()) } catch { result = .failure(error) }
        checks.append(Check(duration: clock.now - readStart, result: result))
        refresh()
    }

    nonisolated static func redact(_ text: String) -> String {
        text.replacing(/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/, with: "<email>")
            .replacing(/([A-Za-z0-9_\-]+)=[^;\s]+/) { "\($0.output.1)=<redacted>" }
            .replacing(/“[^”]*”/, with: "“<name>”")   // how macOS and Parley quote file, space and people names
    }

    /// Plain text for bug reports: states and check results, never cookie values, tokens, messages or addresses.
    struct Report {
        var app: String, os: String
        var connection: ConnectionState, connectedSince: Date?, lastEvent: Date?, reconnects: Int
        var conversations: Int, unread: Int
        var signedIn: Bool
        var signInMethod: String? = nil
        var stored: Bool?, cookies: [CookieRow]
        var checks: [Check]
        var errors: [String]
        var now: Date

        var text: String {
            func ago(_ date: Date?) -> String { date.map { "\(Int(now.timeIntervalSince($0).rounded())) s ago" } ?? "never" }
            func day(_ date: Date?) -> String { date?.formatted(.iso8601) ?? "session" }
            var lines = [
                "Parley Connection Diagnostics",
                "Generated: \(now.formatted(.iso8601))",
                "App: \(app)", "macOS: \(os)", "",
                "Signed in: \(signedIn ? "yes" : "no")",
                "Sign-in method: \(signInMethod.map { $0.hasPrefix("Sign-in window") ? $0 : "\($0) (legacy: sign out and sign in again with the sign-in window)" } ?? "unknown")",
                "Connection: \(ConnectionDiagnostics.status(connection).title)",
                "Connected since: \(connectedSince.map { $0.formatted(.iso8601) } ?? "not connected")",
                "Last event: \(ago(lastEvent))",
                "Reconnects: \(reconnects)",
                "Conversations: \(conversations) (\(unread) unread)", "",
                "Session saved in Keychain: \(stored.map { $0 ? "yes" : "no" } ?? "unknown")",
                "Cookies: \(cookies.count), earliest expiry \(day(cookies.compactMap(\.expires).min()))",
            ]
            lines += cookies.map { "  \($0.name)  \($0.domain)  \(day($0.expires))" }
            lines += ["", "Checks:"] + (checks.isEmpty ? ["  not run"] : checks.map {
                "  \($0.passed ? "✓" : "✗") \($0.name)  \($0.durationText)  \(ConnectionDiagnostics.redact($0.message))"
            })
            lines += ["", "Errors:"] + (errors.isEmpty ? ["  none"] : errors.map { "  " + ConnectionDiagnostics.redact($0) })
            return lines.joined(separator: "\n")
        }
    }
}

extension ConnectionDiagnostics.Check {
    init(duration: Duration, result: Result<ReadCheckResult, Error>) {
        name = "Read check"
        self.duration = duration
        switch result {
        case .success(let read): passed = true; message = "Identity OK · \(read.conversationCount) conversations"
        case .failure(let error): passed = false; message = error.localizedDescription
        }
    }
}

/// The file a user saves and sends with a bug report: the diagnostics summary, this launch's Parley log and the crash
/// reports macOS kept for Parley. Logs carry error kinds and states, never messages or credentials; the home folder is masked.
enum DiagnosticsLog {
    static func text(summary: String, log: [String], crashes: [(name: String, text: String)], home: String = NSHomeDirectory()) -> String {
        var parts = [summary, "", "Log (this launch):"] + (log.isEmpty ? ["  empty"] : log.map { "  " + $0 })
        parts += ["", "Crash reports:"] + (crashes.isEmpty ? ["  none"] : crashes.flatMap { ["", "--- \($0.name)", $0.text] })
        return parts.joined(separator: "\n").replacingOccurrences(of: home, with: "~")
    }
    /// Parley's own entries since launch; the unified log keeps no earlier ones readable here, which crash reports cover.
    static func entries() -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let all = try? store.getEntries(matching: NSPredicate(format: "subsystem == %@", Bundle.main.bundleIdentifier ?? "")) else { return [] }
        return all.compactMap { $0 as? OSLogEntryLog }.map {
            "\($0.date.formatted(.iso8601)) [\($0.category)] \(ConnectionDiagnostics.redact($0.composedMessage))"
        }
    }
    /// The newest crash reports macOS saved for Parley (named Parley before 1.4) in the last two weeks.
    static func crashes(limit: Int = 3) -> [(name: String, text: String)] {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports")
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        let cutoff = Date.now.addingTimeInterval(-14 * 86_400)
        return files.filter { file in file.lastPathComponent.hasPrefix("Parley") }
            .compactMap { url in (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate).map { (url, $0) } }
            .filter { $0.1 > cutoff }.sorted { $0.1 > $1.1 }.prefix(limit)
            .compactMap { url, _ in (try? String(contentsOf: url, encoding: .utf8)).map { (url.lastPathComponent, $0) } }
    }
}

