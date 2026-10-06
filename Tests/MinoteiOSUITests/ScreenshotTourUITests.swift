import XCTest

/// Screenshots of the editor's states, for review (and later the App Store).
/// Skipped unless asked for:
///   TEST_RUNNER_MINOTE_SCREENSHOTS=<name prefix> xcodebuild test … -only-testing:Minote-iOSUITests/ScreenshotTourUITests
/// The shots are attachments of the result bundle (xcresulttool export attachments).
@MainActor
final class ScreenshotTourUITests: XCTestCase {
    private var app: XCUIApplication!
    private let tour = """
    # Markdown tour

    Writing is thinking. **Bold** and _italic_ are typed, never clicked. A ~~mistake~~ stays visible, `code` stays literal, and a [link](https://example.com) keeps its address out of sight.

    ## Lists

    - Plain text, forever
    - Your files, your folders
      - Nested with Tab
    1. First
    2. Second
    - [ ] Write the draft
    - [x] Find a quiet place

    > A quote stands apart, without decoration.

    ```swift
    let note = "Code keeps *its* stars"
    ```

    ---

    | Tool  | Cost |
    |-------|------|
    | Pen   | 2    |
    | Paper | 1    |

    ### Small heading
    The end.

    """

    func testTour() throws {
        guard let prefix = ProcessInfo.processInfo.environment["MINOTE_SCREENSHOTS"] else {
            throw XCTSkip("Set TEST_RUNNER_MINOTE_SCREENSHOTS to take the tour.")
        }
        app = XCUIApplication()
        app.launchEnvironment["MINOTE_UITEST_NOTE"] = tour
        app.launch()
        let editor = app.textViews.firstMatch
        if !editor.waitForExistence(timeout: 3) { app.cells.firstMatch.tap() }
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        func shot(_ name: String) {
            sleep(1)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "\(prefix)-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        func at(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
        }

        shot("01-rendered")
        editor.swipeUp()
        shot("02-rendered-lower-half")
        editor.swipeDown()
        editor.swipeDown()

        // Typing: a tap in the first paragraph brings up the keyboard.
        if isPhone { at(192, 213).tap() } else { editor.tap() }
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        shot("03-editing")
        if isPhone {
            at(193, 293).tap()                // inside "link": its markup shows, for editing
            shot("04-cursor-in-link")
        }

        togglePreview()
        shot("05-preview")
        app.buttons["View"].firstMatch.tap()
        shot("06-view-menu")
        at(10, 400).tap()                     // close the menu
        togglePreview()

        if isPhone {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            shot("07-notes-list")
        }
    }

    /// View menu ▸ Preview.
    private func togglePreview() {
        app.buttons["View"].firstMatch.tap()
        app.buttons["Preview"].firstMatch.tap()
    }
}
