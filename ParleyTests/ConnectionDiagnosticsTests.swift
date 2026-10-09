import Foundation
import SwiftUI
import Testing
@testable import Parley

/// The Connection Diagnostics window's model: no network, a fake Keychain vault and a fake read probe.
@MainActor struct ConnectionDiagnosticsTests {
    private struct FakeVault: SessionVault {
        var data: Data?
        var failure: AuthFailure?
        func read() throws -> Data? { if let failure { throw failure }; return data }
        func write(_ data: Data) throws {}
        func delete() throws {}
    }
    private static let cookies = [
        SessionCookie(name: "SID", value: "secret-sid-value", domain: ".google.com", path: "/", secure: true, expires: 2_000_000_000),
        SessionCookie(name: "COMPASS", value: "secret-compass-value", domain: "chat.google.com", path: "/", secure: true, expires: 1_900_000_000),
        SessionCookie(name: "OSID", value: "secret-osid-value", domain: "chat.google.com", path: "/", secure: true, expires: -1),
    ]
    private static var stored: Data { try! JSONEncoder().encode(WebCredentials(cookies: cookies, userAgent: "Chrome")) }

    private func model(_ vault: FakeVault, probe: @escaping @Sendable () async throws -> ReadCheckResult = {
        ReadCheckResult(conversationCount: 42)
    }) -> ConnectionDiagnostics {
        ConnectionDiagnostics(vault: vault, probe: probe)
    }

    @Test func statusFollowsTheConnectionState() {
        #expect(ConnectionDiagnostics.status(.connected) == .init(title: "Connected", color: .green))
        #expect(ConnectionDiagnostics.status(.connecting) == .init(title: "Connecting", color: .yellow))
        #expect(ConnectionDiagnostics.status(.reconnecting) == .init(title: "Reconnecting", color: .orange))
        #expect(ConnectionDiagnostics.status(.offline) == .init(title: "Offline", color: .gray))
        #expect(ConnectionDiagnostics.status(.signedOut) == .init(title: "Signed out", color: .red))
    }

    @Test func storedSessionShowsAFilledCheckmark() {
        let model = model(FakeVault(data: Self.stored))
        model.refresh()
        #expect(model.stored == true)
        #expect(model.indicator == .init(title: "Saved", symbol: "checkmark.circle.fill", color: .green))
    }
    @Test func missingSessionAndKeychainErrorsAreNotShownAsSaved() {
        let empty = model(FakeVault())
        empty.refresh()
        #expect(empty.stored == false)
        #expect(empty.indicator.symbol == "xmark.circle")
        let failing = model(FakeVault(failure: .keychain(-25308)))
        failing.refresh()
        #expect(failing.stored == nil)
        #expect(failing.indicator.symbol == "questionmark.circle")
        #expect(failing.vaultError != nil)
    }
    @Test func cookieRowsListNamesDomainsAndExpiryOnly() throws {
        let model = model(FakeVault(data: Self.stored))
        model.refresh()
        #expect(model.cookies.map(\.name) == ["COMPASS", "OSID", "SID"])
        #expect(model.cookies.first { $0.name == "OSID" }?.expires == nil)   // session cookie
        #expect(model.earliestExpiry == Date(timeIntervalSince1970: 1_900_000_000))
        let described = String(describing: model.cookies)
        #expect(!described.contains("secret"))
    }
    @Test func aCookieOnlyEntryFromTheFirstBuildsIsNoSession() throws {   // that format is gone; signing in again replaces it
        let model = model(FakeVault(data: try JSONEncoder().encode(Self.cookies)))
        model.refresh()
        #expect(model.cookies.isEmpty)
    }

    @Test func checkRowsCarryResultDurationAndMessage() {
        let passed = ConnectionDiagnostics.Check(duration: .milliseconds(840),
                                                 result: .success(ReadCheckResult(conversationCount: 42)))
        #expect(passed.passed)
        #expect(passed.name == "Read check")
        #expect(passed.message == "Identity OK · 42 conversations")
        #expect(passed.durationText == "0.84 s")
        let failed = ConnectionDiagnostics.Check(duration: .seconds(2), result: .failure(AuthFailure.http(500)))
        #expect(!failed.passed)
        #expect(failed.message == AuthFailure.http(500).localizedDescription)
    }
    @Test func runChecksReadsTheSessionThenTheServer() async {
        let model = model(FakeVault(data: Self.stored))
        await model.runChecks()
        #expect(model.checks.map(\.name) == ["Saved session", "Read check"])
        #expect(model.checks.map(\.passed) == [true, true])
        #expect(!model.running)
    }
    @Test func runChecksStopsWhenSignInIsRequired() async {
        let model = model(FakeVault(data: Self.stored), probe: { throw AuthFailure.signInRequired })
        await model.runChecks()
        #expect(model.checks.map(\.passed) == [true, false])
    }
    @Test func runChecksSkipsGoogleWithoutASession() async {
        let model = model(FakeVault(), probe: { Issue.record("probe ran without a session"); throw AuthFailure.signInRequired })
        await model.runChecks()
        #expect(model.checks.map(\.passed) == [false])
    }

    /// Sign-in is the in-app window only; a session saved some other way (older builds imported browsers' cookies) is legacy.
    @Test func aSessionNotFromTheSignInWindowIsMarkedLegacy() {
        func line(_ method: String?) -> String {
            ConnectionDiagnostics.Report(app: "", os: "", connection: .connected, connectedSince: nil, lastEvent: nil, reconnects: 0,
                                         conversations: 0, unread: 0, signedIn: true, signInMethod: method, stored: true, cookies: [],
                                         checks: [], errors: [], now: .now).text.split(separator: "\n").first { $0.hasPrefix("Sign-in method") }.map(String.init) ?? ""
        }
        #expect(line("Sign-in window (Google sign-in)") == "Sign-in method: Sign-in window (Google sign-in)")
        #expect(line("Safari") == "Sign-in method: Safari (legacy: sign out and sign in again with the sign-in window)")
        #expect(line(nil) == "Sign-in method: unknown")
    }
    @Test func reportIsRedacted() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let model = model(FakeVault(data: Self.stored))
        model.refresh()
        model.checks = [ConnectionDiagnostics.Check(duration: .seconds(1),
                                                    result: .failure(AuthFailure.bootstrapRedirect("someone@example.com")))]
        let report = ConnectionDiagnostics.Report(
            app: "1.0 (1)", os: "Version 26.0", connection: .connected, connectedSince: now.addingTimeInterval(-60),
            lastEvent: now.addingTimeInterval(-5), reconnects: 2, conversations: 42, unread: 3, signedIn: true,
            signInMethod: "Sign-in window (Chrome)", stored: model.stored, cookies: model.cookies, checks: model.checks,
            errors: ["Couldn’t reach someone@example.com", "SID=secret-sid-value"], now: now).text
        #expect(report.contains("Connection: Connected"))
        #expect(report.contains("Reconnects: 2"))
        #expect(report.contains("Sign-in method: Sign-in window (Chrome)"))
        #expect(report.contains("Last event: 5 s ago"))
        #expect(report.contains("Conversations: 42 (3 unread)"))
        #expect(report.contains("Cookies: 3"))
        #expect(report.contains("SID"))
        #expect(report.contains("✗ Read check "))
        #expect(!report.contains("@"))
        #expect(!report.contains("secret"))
        #expect(report.contains("<email>"))
    }
    @Test func redactionHidesEmailsAndCookieAssignments() {
        #expect(ConnectionDiagnostics.redact("from a.b+c@mail.example.org now") == "from <email> now")
        #expect(ConnectionDiagnostics.redact("Cookie: SID=abc; HSID=def") == "Cookie: SID=<redacted>; HSID=<redacted>")
        #expect(ConnectionDiagnostics.redact("“Q3 plan.pdf” is empty. “Marketing” too.") == "“<name>” is empty. “<name>” too.")
    }

    @Test func storeTracksConnectionHistory() {
        let store = ChatStore(backend: FakeBackend())
        var clock = Date(timeIntervalSince1970: 1_000)
        store.now = { clock }
        store.apply(.connectionChanged(.connected))
        #expect(store.connectedSince == clock)
        #expect(store.lastEventAt == nil)   // a state change isn't an event from Google
        clock += 10
        store.apply(.readStateChanged("room", unread: 0))
        #expect(store.lastEventAt == clock)
        store.apply(.connectionChanged(.reconnecting))
        store.apply(.connectionChanged(.reconnecting))
        #expect(store.reconnects == 1)
        #expect(store.connectedSince == nil)
        store.apply(.connectionChanged(.connected))
        #expect(store.connectedSince == clock)
    }
    @Test func savedLogHoldsSummaryLogAndCrashesWithTheHomeFolderMasked() {
        let text = DiagnosticsLog.text(summary: "Parley Connection Diagnostics", log: ["2026-10-07 [store] HTTP 500"],
                                       crashes: [(name: "Parley-2026-10-07.ips", text: "Path: /Users/friend/Applications/Parley.app")],
                                       home: "/Users/friend")
        #expect(text.hasPrefix("Parley Connection Diagnostics"))
        #expect(text.contains("  2026-10-07 [store] HTTP 500"))
        #expect(text.contains("--- Parley-2026-10-07.ips\nPath: ~/Applications/Parley.app"))
        #expect(!text.contains("/Users/friend"))
        let empty = DiagnosticsLog.text(summary: "S", log: [], crashes: [], home: "/Users/friend")
        #expect(empty == "S\n\nLog (this launch):\n  empty\n\nCrash reports:\n  none")
    }
    @Test func reportedErrorsReachTheSavedLogRedacted() {
        let store = ChatStore(backend: FakeBackend())
        let marker = UUID().uuidString
        store.report(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(marker) for someone@example.com"]))
        let line = DiagnosticsLog.entries().first { $0.contains(marker) }
        #expect(line?.contains("[store]") == true && line?.contains("<email>") == true, "\(String(describing: line))")
    }
}
