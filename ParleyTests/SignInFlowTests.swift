import Foundation
import Testing
@testable import Parley

/// The welcome screen's sign-in flow over a fake browser, a fake session store and a fake clock.
@MainActor struct SignInFlowTests {
    private final class FakeBrowser: SignInBrowser {
        var startError: Error?
        /// Captures in order; the last one repeats.
        var captures: [Result<WebCredentials, Error>] = [.failure(AuthFailure.chatNotOpen)]
        var starts = 0, closes = 0, captured = 0
        func start() async throws { starts += 1; if let startError { throw startError } }
        func captureSession() async throws -> WebCredentials {
            captured += 1
            let next = captures.count > 1 ? captures.removeFirst() : captures[0]
            return try next.get()
        }
        func close() { closes += 1 }
        var forgets = 0
        func forget() async { forgets += 1 }
    }
    private actor FakeSessions: SessionImporter {
        var failures: [Error] = []
        private(set) var imported: [[SessionCookie]] = []
        private(set) var signOuts = 0
        func failNext(_ errors: [Error]) { failures = errors }
        func signIn(cookies: [SessionCookie], userAgent: String) async throws {
            if !failures.isEmpty { throw failures.removeFirst() }
            imported.append(cookies)
        }
        func signOut() async throws { signOuts += 1 }
    }
    private final class Clock { var now = Date(timeIntervalSince1970: 1_000_000) }
    private static let session = WebCredentials(cookies: [SessionCookie(name: "SID", value: "a", domain: ".google.com", path: "/", secure: true, expires: 0)], userAgent: "Chrome")

    /// A flow whose every pause moves the clock 1.5 s; `pauses` caps the polls so a stuck flow ends the test.
    private func flow(_ browser: FakeBrowser, _ sessions: FakeSessions, pauses: Int = 100) -> (SignInFlow, Clock) {
        let clock = Clock()
        let flow = SignInFlow(browser: browser, importer: sessions)
        flow.now = { clock.now }
        var left = pauses
        flow.pause = {
            left -= 1
            guard left >= 0 else { throw CancellationError() }
            clock.now += 1.5
            await Task.yield()
        }
        return (flow, clock)
    }

    @Test func importsOnceChatLoadsAndClosesTheBrowser() async {
        let browser = FakeBrowser(), sessions = FakeSessions()
        browser.captures = [.failure(AuthFailure.chatNotOpen), .failure(AuthFailure.chatNotOpen), .success(Self.session)]
        let (flow, _) = flow(browser, sessions)
        var signedIn = 0
        flow.onSignedIn = { signedIn += 1 }
        flow.start()
        #expect(flow.phase == .opening)
        await flow.task?.value
        #expect(flow.phase == .signedIn)
        #expect(await sessions.imported == [Self.session.cookies])
        #expect(browser.captured == 3 && browser.closes == 1 && signedIn == 1)
        #expect(UserDefaults.standard.string(forKey: SignInFlow.methodKey) == SignInFlow.method)
        #expect(flow.error == nil && !flow.offerManual)
    }

    @Test func keepsWaitingWhileChatHasNoUsableSession() async {
        let browser = FakeBrowser(), sessions = FakeSessions()
        browser.captures = [.success(Self.session)]
        await sessions.failNext([AuthFailure.bootstrapRedirect("Google sign-in"), AuthFailure.invalidSession])
        let (flow, _) = flow(browser, sessions)
        flow.start()
        await flow.task?.value
        #expect(flow.phase == .signedIn)
        #expect(browser.captured == 3)
        #expect(flow.error == nil)   // automatic retries stay quiet
    }

    @Test func offersManualConfirmationTwentySecondsAfterChatLoads() async {
        let browser = FakeBrowser(), sessions = FakeSessions()
        // Ten polls on the sign-in page (15 s) never count toward the delay.
        browser.captures = Array(repeating: .failure(AuthFailure.chatNotOpen), count: 10) + [.success(Self.session)]
        await sessions.failNext(Array(repeating: AuthFailure.bootstrapTokenMissing, count: 100))
        let (flow, clock) = flow(browser, sessions, pauses: 24)
        let opened = clock.now
        flow.start()
        await flow.task?.value
        // Chat loaded at 15 s; 20 s later the fallback appears.
        #expect(flow.offerManual)
        #expect(clock.now.timeIntervalSince(opened) >= 35)

        let early = FakeBrowser(), more = FakeSessions()
        early.captures = Array(repeating: .failure(AuthFailure.chatNotOpen), count: 10) + [.success(Self.session)]
        await more.failNext(Array(repeating: AuthFailure.bootstrapTokenMissing, count: 100))
        let (quick, _) = self.flow(early, more, pauses: 20)   // stops at 30 s: only 15 s after chat loaded
        quick.start()
        await quick.task?.value
        #expect(!quick.offerManual)
    }

    @Test func manualConfirmationImportsNowOrSaysWhy() async {
        let browser = FakeBrowser(), sessions = FakeSessions()
        let (flow, _) = flow(browser, sessions, pauses: 0)
        flow.start()
        await flow.task?.value   // the only poll found no chat page; the browser stays open
        #expect(flow.phase == .waiting)
        await flow.confirm()
        #expect(flow.phase == .waiting)
        #expect(flow.error == AuthFailure.chatNotOpen.localizedDescription)

        browser.captures = [.success(Self.session)]
        await flow.confirm()
        #expect(flow.phase == .signedIn)
        #expect(flow.error == nil)
        #expect(browser.closes == 1)
    }

    @Test func cancelClosesTheBrowserAndReturnsToWelcome() async {
        let browser = FakeBrowser(), sessions = FakeSessions()
        let (flow, _) = flow(browser, sessions)
        flow.pause = { try await Task.sleep(for: .seconds(60)) }
        flow.start()
        while browser.captured == 0 { await Task.yield() }
        flow.cancel()
        await flow.task?.value
        #expect(flow.phase == .idle)
        #expect(flow.error == nil)
        #expect(browser.closes >= 1)
        #expect(await sessions.imported.isEmpty)
    }

    @Test func closingTheBrowserEndsTheAttempt() async {
        let browser = FakeBrowser(), sessions = FakeSessions()
        browser.captures = [.failure(AuthFailure.chatNotOpen), .failure(AuthFailure.browserClosed)]
        let (flow, _) = flow(browser, sessions)
        flow.start()
        await flow.task?.value
        #expect(flow.phase == .idle)
        #expect(flow.error == AuthFailure.browserClosed.localizedDescription)
        // A new attempt starts clean.
        browser.captures = [.success(Self.session)]
        flow.start()
        #expect(flow.error == nil)
        await flow.task?.value
        #expect(flow.phase == .signedIn)
    }

    @Test func startIsIgnoredWhileSigningIn() async {
        let browser = FakeBrowser(), sessions = FakeSessions()
        browser.captures = [.success(Self.session)]
        let (flow, _) = flow(browser, sessions)
        flow.start()
        flow.start()
        await flow.task?.value
        #expect(browser.starts == 1)
    }

    @Test func expiredSessionSignsInAgainAndResumesWithDraftsKept() async {
        let fake = FakeBackend()
        let store = ChatStore(backend: fake)
        await store.start()
        await until { store.connection == .connected }
        #expect(!store.me.id.isEmpty)
        store.drafts["alex/timeline"] = "half a thought"
        let conversations = store.conversations.count

        store.apply(.connectionChanged(.signedOut))   // the backend lost the session while running
        #expect(store.sessionExpired)
        #expect(!store.needsSignIn)

        let browser = FakeBrowser(), sessions = FakeSessions()
        browser.captures = [.success(Self.session)]
        let (flow, _) = flow(browser, sessions)
        flow.onSignedIn = { await store.start() }
        flow.start()
        await flow.task?.value
        await until { store.connection == .connected }
        #expect(!store.sessionExpired)
        #expect(store.drafts["alex/timeline"] == "half a thought")
        #expect(store.conversations.count == conversations)
    }

    @Test func launchingWithoutASessionNeedsSignIn() async {
        let fake = FakeBackend()
        await fake.simulateSignedOut()
        let store = ChatStore(backend: fake)
        await store.start()
        #expect(store.needsSignIn)
        #expect(!store.sessionExpired)
    }

    @Test func signingOutClearsTheSessionAndReturnsToWelcome() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        let browser = FakeBrowser(), sessions = FakeSessions()
        let (flow, _) = flow(browser, sessions)
        try await flow.signOut()
        store.signedOut()
        #expect(await sessions.signOuts == 1)
        #expect(browser.forgets == 1)   // the next sign-in starts without Google remembering the account
        #expect(store.needsSignIn)
        #expect(store.me.id.isEmpty)
    }
    /// Lets the store's event task apply what the fake backend already emitted.
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

/// Silent renewal: the session Google ended comes back without a window, at most once per `renewalSpacing`.
extension SignInFlowTests {
    private final class FakeRenewer: SessionRenewing {
        var result: Result<WebCredentials, Error> = .success(SignInFlowTests.session)
        var renewals = 0
        func renew() async throws -> WebCredentials { renewals += 1; return try result.get() }
    }
    @Test func renewsSilentlyAndImportsTheFreshSession() async {
        let sessions = FakeSessions(), renewer = FakeRenewer()
        let (flow, clock) = flow(FakeBrowser(), sessions)
        flow.renewer = renewer
        #expect(await flow.renewSilently())
        #expect(await sessions.imported == [Self.session.cookies])
        #expect(!(await flow.renewSilently()))                  // again at once: refused, so a refused session can't loop
        #expect(renewer.renewals == 1)
        #expect(await flow.renewSilently(force: true))          // Connection Diagnostics' button
        clock.now += SignInFlow.renewalSpacing
        #expect(await flow.renewSilently())
        #expect(renewer.renewals == 3)
    }
    @Test func aRenewalGoogleRefusesLeavesTheBannerToAsk() async {
        let sessions = FakeSessions(), renewer = FakeRenewer()
        renewer.result = .failure(AuthFailure.signInRequired)
        let (flow, _) = flow(FakeBrowser(), sessions)
        flow.renewer = renewer
        #expect(!(await flow.renewSilently()))
        #expect(await sessions.imported.isEmpty)
        let (plain, _) = self.flow(FakeBrowser(), FakeSessions())   // no renewer: nothing to try
        #expect(!(await plain.renewSilently()))
    }
}
