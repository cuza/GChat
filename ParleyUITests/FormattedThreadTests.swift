import XCTest

/// Seen live: opening the thread of a long bold-and-list reply (an assistant's answer) crashed the app in a layout loop.
@MainActor final class FormattedThreadTests: XCTestCase {
    func testOpeningAThreadWithAFormattedListReplyDoesNotCrash() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingFormattedThread"]
        app.launch()
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Assistant")).firstMatch.click()
        let replies = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "1 reply")).firstMatch
        XCTAssertTrue(replies.waitForExistence(timeout: 5), "the thread link never showed")
        replies.click()
        XCTAssertTrue(app.staticTexts["Thread"].waitForExistence(timeout: 5), "the thread panel never opened")
        sleep(3)   // the crash came a moment after the panel laid out
        XCTAssertEqual(app.state, .runningForeground, "the app quit after opening the thread")
        // The pane widens the window instead of squeezing the conversation.
        let timeline = app.scrollViews["timeline"]
        XCTAssertTrue(timeline.exists)
        XCTAssertGreaterThanOrEqual(timeline.frame.width, 380, "the conversation was squeezed to \(timeline.frame.width) pt")
    }
}

