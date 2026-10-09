import Foundation
import Testing
@testable import Parley

struct UpdatesTests {
    @Test func theAppDeclaresItsFeedAndKey() {
        let info = Bundle.main.infoDictionary ?? [:]   // the test host is Parley.app
        #expect(info["SUFeedURL"] as? String == "https://github.com/cuza/Parley/releases/latest/download/appcast.xml")
        #expect((info["SUPublicEDKey"] as? String)?.isEmpty == false)
    }
    @Test func onlyALiveReleaseBuildChecksForUpdates() {
        #expect(Updates.shouldStart(live: true, debug: false))
        #expect(!Updates.shouldStart(live: true, debug: true))    // an Xcode run shares the installed app's bundle ID
        #expect(!Updates.shouldStart(live: false, debug: false))  // tests, the demo and UI-testing launches
    }
    @MainActor @Test func anUnstartedUpdaterHasNoMenuItem() {
        let updates = Updates(start: false)
        #expect(!updates.isActive && !updates.canCheck)
    }
}
