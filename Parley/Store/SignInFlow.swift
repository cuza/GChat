import Foundation
import Observation
import OSLog

let authLog = Logger(subsystem: "dev.cuza.Parley", category: "auth")

/// The in-app sign-in window as the flow drives it; tests replace it.
@MainActor protocol SignInBrowser: AnyObject {
    func start() async throws
    /// Throws `AuthFailure.chatNotOpen` until a Google Chat page is open.
    func captureSession() async throws -> WebCredentials
    func close()
    /// Deletes everything the sign-in window stored, so the next sign-in starts fresh.
    func forget() async
}
extension SignInBrowser {
    func forget() async {}
}
/// Where a captured session goes: checked against Google Chat, then kept in the Keychain.
protocol SessionImporter: Sendable {
    func signIn(cookies: [SessionCookie], userAgent: String) async throws
    func signOut() async throws
}
extension WebSessionAuthorizer: SessionImporter {}

/// Sign-in from the welcome screen or the expiry banner: opens the sign-in window, waits until
/// Google Chat has loaded with a usable session, imports it and closes the window.
@MainActor @Observable
final class SignInFlow {
    enum Phase: Equatable { case idle, opening, waiting, finishing, signedIn }
    private(set) var phase = Phase.idle
    private(set) var error: String?
    /// Google Chat loaded a while ago but nothing imported yet: offer "I've signed in".
    private(set) var offerManual = false
    static let manualDelay: TimeInterval = 20
    var busy: Bool { phase != .idle && phase != .signedIn }

    @ObservationIgnored var onSignedIn: @MainActor () async -> Void = {}
    /// How the saved session was obtained, for diagnostics. The in-app sign-in window is the only way now; anything else
    /// saved here came from an older build and diagnostics marks it legacy.
    static let methodKey = "signInMethod", method = "Sign-in window"
    @ObservationIgnored var now: () -> Date = { .now }
    @ObservationIgnored var pause: () async throws -> Void = { try await Task.sleep(for: .seconds(1.5)) }
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private let browser: any SignInBrowser
    @ObservationIgnored private let importer: any SessionImporter
    @ObservationIgnored private var chatSince: Date?

    init(browser: any SignInBrowser, importer: any SessionImporter) {
        self.browser = browser; self.importer = importer
    }

    func start() {
        guard !busy else { return }
        error = nil; offerManual = false; chatSince = nil
        phase = .opening
        task = Task { await run() }
    }
    func cancel() {
        task?.cancel()
        browser.close()
        if busy { phase = .idle }
        offerManual = false
    }
    /// The manual fallback: import now, and say why when it can't.
    func confirm() async {
        guard phase == .waiting else { return }
        if let failure = await attempt() { error = failure.localizedDescription }
    }
    /// Signs in again without a window, through the Google account the sign-in window remembers; false when Google
    /// wants the user (or there is no renewer), for the session-expired banner to ask. At most once per
    /// `renewalSpacing` unless forced, so a session Google keeps refusing can't loop.
    @ObservationIgnored var renewer: (any SessionRenewing)?
    @ObservationIgnored private var lastRenewal: Date?
    static let renewalSpacing: TimeInterval = 600
    func renewSilently(force: Bool = false) async -> Bool {
        guard let renewer, !busy else { return false }
        if !force, let lastRenewal, now().timeIntervalSince(lastRenewal) < Self.renewalSpacing { return false }
        lastRenewal = now()
        do {
            let credentials = try await renewer.renew()
            try await importer.signIn(cookies: credentials.cookies, userAgent: credentials.userAgent)
            authLog.notice("Session renewed silently")
            return true
        } catch {
            authLog.notice("Silent renewal failed: \(Self.kind(error), privacy: .public)")
            return false
        }
    }
    /// Removes the stored session and the sign-in window's data; the caller returns the app to the welcome screen.
    func signOut() async throws {
        cancel()
        try await importer.signOut()
        await browser.forget()
        phase = .idle
    }

    private func run() async {
        do { try await browser.start() } catch {
            guard !Task.isCancelled else { return }
            return stop(error)
        }
        guard !Task.isCancelled else { return }
        phase = .waiting
        while !Task.isCancelled, busy {
            if phase == .waiting, let failure = await attempt() {
                if (failure as? AuthFailure) == .browserClosed { return stop(failure) }
                // A Keychain or Google refusal would otherwise hide behind the spinner until the manual button appears.
                if !Self.stillSigningIn(failure) { error = failure.localizedDescription }
            }
            if phase == .signedIn { return }
            if let chatSince, now().timeIntervalSince(chatSince) >= Self.manualDelay { offerManual = true }
            do { try await pause() } catch { return }
        }
    }
    /// Expected while the user is still in the browser: no cookies yet, or Google Chat not open yet.
    private static func stillSigningIn(_ failure: Error) -> Bool {
        switch failure as? AuthFailure {
        case .signInRequired, .chatNotOpen, .invalidSession: true
        default: false
        }
    }
    /// One capture and import; nil once signed in or when another attempt is already finishing.
    private func attempt() async -> Error? {
        do {
            let credentials = try await browser.captureSession()
            chatSince = chatSince ?? now()
            guard phase == .waiting else { return nil }
            phase = .finishing
            do {
                try await importer.signIn(cookies: credentials.cookies, userAgent: credentials.userAgent)
            } catch {
                authLog.notice("Sign-in: Google Chat refused the new session: \(Self.kind(error), privacy: .public)")
                if phase == .finishing { phase = .waiting }
                return error
            }
            guard phase == .finishing else { return nil }   // cancelled meanwhile
            browser.close()
            error = nil; offerManual = false
            phase = .signedIn
            UserDefaults.standard.set(Self.method, forKey: Self.methodKey)
            authLog.notice("Signed in")
            await onSignedIn()
            return nil
        } catch { return error }
    }
    /// For the log: the failure's kind, never a URL or cookie.
    static func kind(_ error: Error) -> String {
        if let failure = error as? AuthFailure { return String(describing: failure) }
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
    private func stop(_ failure: Error) {
        browser.close()
        phase = .idle
        error = failure.localizedDescription
    }
}
