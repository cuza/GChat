import Foundation
import Testing
@testable import Parley

/// The hidden renewal visit: done once Google Chat is reached with a session, stopped as soon as Google wants the user.
@MainActor struct SessionRenewerTests {
    private final class FakeData: SignInWebData {
        var stored: [HTTPCookie] = []
        func cookies() async -> [HTTPCookie] { stored }
        func removeAll() async { stored = [] }
    }
    private static func cookie(_ name: String, domain: String = ".google.com") -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: "v-\(name)", .domain: domain, .path: "/", .secure: "TRUE"])!
    }
    private static let session = [cookie("__Secure-1PSID"), cookie("OSID", domain: "chat.google.com"), cookie("COMPASS", domain: "chat.google.com")]
    private func renewer(_ data: FakeData, visits: [String]) -> SessionRenewer {
        let renewer = SessionRenewer(data: data)
        renewer.timeout = .milliseconds(300); renewer.poll = .milliseconds(10)
        renewer.open = { renewer in visits.forEach { renewer.reached(URL(string: $0)!) } }
        return renewer
    }

    @Test func reachingGoogleChatWithASessionRenews() async throws {
        let data = FakeData(); data.stored = Self.session
        let credentials = try await renewer(data, visits: ["https://accounts.google.com/ServiceLogin?passive=true", "https://chat.google.com/"]).renew()
        #expect(Set(credentials.cookies.map(\.name)) == ["__Secure-1PSID", "OSID", "COMPASS"])
        #expect(credentials.userAgent.contains("Safari/") && credentials.userAgent.contains("Version/"))
    }
    @Test func googleWantingTheUserStopsTheRenewal() async {
        let data = FakeData(); data.stored = Self.session
        await #expect(throws: AuthFailure.signInRequired) {
            _ = try await renewer(data, visits: ["https://accounts.google.com/v3/signin/identifier?continue=x"]).renew()
        }
    }
    @Test func neverReachingGoogleChatTimesOut() async {
        await #expect(throws: AuthFailure.chatNotOpen) { _ = try await renewer(FakeData(), visits: []).renew() }
        let data = FakeData()   // reached, but without a session (no OSID): not done either
        data.stored = [Self.cookie("__Secure-1PSID")]
        await #expect(throws: AuthFailure.chatNotOpen) { _ = try await renewer(data, visits: ["https://chat.google.com/"]).renew() }
    }
    @Test func whichGooglePagesNeedTheUser() {
        for page in ["https://accounts.google.com/v3/signin/challenge/pwd", "https://accounts.google.com/signin/v2/identifier",
                     "https://accounts.google.com/AccountChooser?continue=x", "https://accounts.google.co.uk/v3/signin/identifier"] {
            #expect(SessionRenewer.wantsUser(URL(string: page)!), "\(page)")
        }
        for page in ["https://accounts.google.com/ServiceLogin?passive=true", "https://accounts.google.com/CheckCookie",
                     "https://chat.google.com/accounts/SetOSID?x=1", "https://chat.google.com/"] {
            #expect(!SessionRenewer.wantsUser(URL(string: page)!), "\(page)")
        }
    }
}

/// A session that ends while in use is handed to the silent renewal once; a sign-out before any account is not.
@MainActor struct SessionLostTests {
    @Test func aLostSessionAsksForRenewalOnce() async {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        var asked = 0
        store.onSessionLost = { asked += 1 }
        store.connection = .signedOut
        store.connection = .signedOut
        for _ in 0..<5 { await Task.yield() }
        #expect(asked == 1)
        store.signedOut()   // the user signed out: me is cleared first, so nothing renews
        store.connection = .connected
        store.signedOut()
        for _ in 0..<5 { await Task.yield() }
        #expect(asked == 1)
    }
}
