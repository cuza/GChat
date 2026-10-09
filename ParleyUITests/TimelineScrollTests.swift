import XCTest

/// Drives the real app over a long fake history (600 messages in Engineering, 50 per page, 300 ms per page).
/// Under -uiTestingLongHistory the timeline reports "<row id at the vertical centre> of <row count>" as its accessibility
/// value: polling row elements makes XCUITest snapshot every hosted cell and takes seconds per query.
@MainActor final class TimelineScrollTests: XCTestCase {
    private var app: XCUIApplication!
    private var timeline: XCUIElement { app.scrollViews["timeline"] }
    private var state: (middle: String, count: Int) {
        let parts = (timeline.value as? String ?? "").components(separatedBy: " of ")
        return (parts.first ?? "", Int(parts.last ?? "") ?? 0)
    }
    /// Scrolls the timeline up by `points`, at its centre (the table itself has no hit point for XCUITest).
    private func scroll(_ points: CGFloat) { timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).scroll(byDeltaX: 0, deltaY: points) }
    private func wait(_ what: String, until condition: () -> Bool) {
        for _ in 0..<40 where !condition() { usleep(250_000) }
        XCTAssertTrue(condition(), what)
    }

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestingLongHistory"]
        app.launch()
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Engineering,")).firstMatch.click()
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        scroll(-1)   // a first scroll publishes the state
        wait("the newest page never showed") { state.count == 50 }
    }

    /// The row being read stays put when the older page above it lands.
    func testReadingPositionHoldsWhileAnOlderPageLoads() {
        for _ in 0..<40 where state.count == 50 { scroll(150) }   // creep up until the older page starts loading
        let reading = state.middle
        XCTAssertTrue(reading.hasPrefix("e5"), "expected to be reading the newest page, got \(reading)")
        wait("the older page never loaded") { state.count == 100 }
        scroll(-1); scroll(1)                            // nudge so the state is re-published after the page lands
        XCTAssertEqual(state.middle, reading, "the reader was moved off the row they were reading")
    }
}
