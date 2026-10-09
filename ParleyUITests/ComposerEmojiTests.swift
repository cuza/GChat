import XCTest

/// The composer's emoji button opens Parley's picker beside the button, and a pick goes into the draft.
@MainActor final class ComposerEmojiTests: XCTestCase {
    func testThePickerOpensAtTheButtonAndInsertsIntoTheDraft() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingFormattedThread"]
        app.launch()
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Assistant")).firstMatch.click()
        let button = app.buttons["Emoji"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.click()
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5), "the picker never opened")
        let (picker, anchor) = (popover.frame, button.frame)
        XCTAssertTrue(picker.minX < anchor.midX && anchor.midX < picker.maxX, "picker \(picker) is not over the button \(anchor)")
        XCTAssertLessThan(abs(anchor.minY - picker.maxY), 30, "picker \(picker) is not just above the button \(anchor)")
        popover.textFields.firstMatch.typeText("fox face\r")
        XCTAssertTrue(popover.waitForNonExistence(timeout: 5), "picking didn't close the picker")
        let field = app.textViews["composer"]
        XCTAssertEqual(field.value as? String, "🦊")
        field.typeText("!")   // the field has the focus back
        XCTAssertEqual(field.value as? String, "🦊!")
    }
}
