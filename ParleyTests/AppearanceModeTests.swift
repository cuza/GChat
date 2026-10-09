import AppKit
import Testing
@testable import Parley

@MainActor struct AppearanceModeTests {
    @Test func theChosenModeSetsTheAppsAppearance() {
        let defaults = UserDefaults.standard, saved = defaults.string(forKey: AppearanceMode.key)
        defer { defaults.set(saved, forKey: AppearanceMode.key); AppearanceMode.apply() }
        defaults.set("dark", forKey: AppearanceMode.key); AppearanceMode.apply()
        #expect(NSApplication.shared.appearance?.name == .darkAqua)
        defaults.set("light", forKey: AppearanceMode.key); AppearanceMode.apply()
        #expect(NSApplication.shared.appearance?.name == .aqua)
        defaults.set("auto", forKey: AppearanceMode.key); AppearanceMode.apply()
        #expect(NSApplication.shared.appearance == nil)   // follows macOS
    }
}
