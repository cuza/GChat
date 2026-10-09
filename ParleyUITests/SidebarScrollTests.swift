import XCTest

/// Drives the real app over a large fake account (-uiTestingManyConversations: 326 conversations).
@MainActor final class SidebarScrollTests: XCTestCase {
    private func row(_ sidebar: XCUIElement, _ prefix: String) -> XCUIElement {
        sidebar.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// The sidebar scrolls to its last conversation, which can be selected; opening it reads it.
    func testScrollsToTheBottomAndSelectsTheLastConversation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingManyConversations"]
        app.launch()
        let sidebar = app.descendants(matching: .any)["sidebar"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        XCTAssertTrue(row(sidebar, "Design studio,").waitForExistence(timeout: 5))
        let last = row(sidebar, "Space 320,")
        for _ in 0..<60 where !(last.exists && last.isHittable) {
            sidebar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).scroll(byDeltaX: 0, deltaY: -3_000)
        }
        XCTAssertTrue(last.isHittable, "the last conversation never scrolled into view")
        XCTAssertEqual(last.label, "Space 320, 320 unread")
        last.click()
        let read = row(sidebar, "Space 320, 0 unread")
        XCTAssertTrue(read.waitForExistence(timeout: 5), "selecting the last conversation didn't open and read it")
        XCTAssertTrue(app.staticTexts["Start the conversation"].waitForExistence(timeout: 5))
        XCTAssertTrue(read.isHittable, "the sidebar jumped away from the selected row")
    }
}
