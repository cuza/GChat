import Combine
import Sparkle
import SwiftUI

/// Sparkle's standard updater: a daily check (it asks once, on the second launch), an update window with the release
/// notes, and Parley ▸ Check for Updates…. Only a live release build starts it.
@MainActor final class Updates: ObservableObject {
    private let controller: SPUStandardUpdaterController?
    @Published private(set) var canCheck = false

    /// Tests, the demo and UI-testing launches aren't live; a Debug run shares the installed app's bundle ID, and must
    /// never replace itself with a release build.
    nonisolated static func shouldStart(live: Bool, debug: Bool) -> Bool { live && !debug }

    init(start: Bool) {
        guard start else { controller = nil; return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).assign(to: &$canCheck)
    }

    var isActive: Bool { controller != nil }
    func check() { controller?.checkForUpdates(nil) }
}

struct CheckForUpdatesItem: View {
    @ObservedObject var updates: Updates
    var body: some View {
        if updates.isActive { Button("Check for Updates…") { updates.check() }.disabled(!updates.canCheck) }
    }
}
