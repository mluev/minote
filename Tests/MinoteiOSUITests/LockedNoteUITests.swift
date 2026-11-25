import XCTest

/// A locked note on iOS: sealed until its password is given (the simulator
/// has no Face ID to offer), and locked again as soon as Minote leaves the screen.
@MainActor
final class LockedNoteUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["MINOTE_UITEST_NOTE"] = "Plain note\n"
        // Seeds "Locked Test.mdlock", sealed with this password (hint: "the test one").
        app.launchEnvironment["MINOTE_UITEST_LOCKED"] = "uitest-password"
        app.launch()
    }

    private var editorText: String { app.textViews.firstMatch.value as? String ?? "" }
    private var passwordField: XCUIElement { app.secureTextFields["unlockPassword"] }

    private func wait(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    func testALockedNoteOpensWithItsPasswordAndLocksAgainInTheBackground() {
        let row = app.staticTexts["Locked Test"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        XCTAssertFalse(editorText.contains("hidden line"))

        // The first wrong password offers a way back, not the hint yet.
        passwordField.tap()
        passwordField.typeText("wrong\n")
        XCTAssertTrue(app.staticTexts["Wrong password."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Forgot Password?"].exists)
        // The hint, after a few.
        for _ in 0..<2 {
            passwordField.tap()
            passwordField.typeText("wrong\n")
        }
        XCTAssertTrue(app.staticTexts["Wrong password. Hint: the test one"].waitForExistence(timeout: 5))

        passwordField.tap()
        passwordField.typeText("uitest-password\n")
        XCTAssertTrue(wait { self.editorText.contains("The hidden line") }, editorText)
        XCTAssertFalse(passwordField.exists)

        // Leaving Minote locks it: back on screen, the note is shut again.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        XCTAssertFalse(editorText.contains("hidden line"))
    }
}
