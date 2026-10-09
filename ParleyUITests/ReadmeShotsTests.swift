import XCTest

/// Regenerates the README screenshots from the demo workspace: run it alone, then copy the PNGs it writes to the
/// test runner's temporary directory into Screenshots/.
@MainActor final class ReadmeShotsTests: XCTestCase {
    private func shoot(_ name: String, dark: Bool = false, open: String? = nil) throws {
        let app = XCUIApplication()
        // The look is pinned here, not taken from this Mac's settings: no wallpaper, accent bubbles.
        app.launchArguments = ["-uiTestingDemo", "-wallpaper", "none", "-wallpaperDark", "none", "-wallpaperDoodles", "NO",
                               "-bubbleColor", "", "-bubbleColorDark", ""] + (dark ? ["-uiTestingDark"] : [])
        app.launch()
        let replies = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ AND elementType != %d", "2 replies",
                                                                                        XCUIElement.ElementType.scrollView.rawValue)).firstMatch   // the link, not the timeline around it
        XCTAssertTrue(replies.waitForExistence(timeout: 5))
        if open == "thread" { replies.click() }
        if open == "home" { app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", "Home")).firstMatch.click() }
        // The app DM's row has an unread badge, so it reads as one element labelled "Notebook, 1 unread".
        if open == "apps" { app.descendants(matching: .any).matching(NSPredicate(format: "value == %@ OR label BEGINSWITH %@", "Notebook", "Notebook,")).firstMatch.click() }
        if open == "info" { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Design studio")).firstMatch.click() }
        // Park the pointer on empty sidebar space so no hover tooltip is captured.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.8)).hover()
        sleep(3)
        try app.windows.firstMatch.screenshot().pngRepresentation.write(to: URL(filePath: NSTemporaryDirectory()).appending(path: "\(name).png"))
        app.terminate()
    }
    func testReadmeScreenshots() throws {
        try shoot("home", open: "home")
        try shoot("conversation")
        try shoot("thread-dark", dark: true, open: "thread")
        try shoot("info", open: "info")
        try shoot("apps", open: "apps")
    }
}
