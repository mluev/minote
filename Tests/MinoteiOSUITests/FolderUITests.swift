import XCTest

/// Folders in the iPhone list: they open and close, and a note moves into
/// one from its menu.
@MainActor
final class FolderUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["MINOTE_UITEST_NOTE"] = "UI Test\nA note at the top"
        app.launchEnvironment["MINOTE_UITEST_FOLDER"] = "Projects"
        app.launch()
        // The editor may open first on iPhone: go back to the list.
        let back = app.navigationBars.buttons.firstMatch
        if !app.buttons["Projects"].waitForExistence(timeout: 3), back.exists { back.tap() }
        XCTAssertTrue(app.buttons["Projects"].waitForExistence(timeout: 5))
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFoldersOpenAndClose() {
        let filed = app.staticTexts["Filed Note"]
        XCTAssertTrue(filed.waitForExistence(timeout: 3))
        snapshot("1-open")
        app.buttons["Projects"].tap()
        XCTAssertTrue(filed.waitForNonExistence(timeout: 3))
        snapshot("2-closed")
        app.buttons["Projects"].tap()
        XCTAssertTrue(filed.waitForExistence(timeout: 3))
    }

    func testANoteMovesIntoAFolderFromItsMenu() {
        let note = app.staticTexts["UI Test"]
        XCTAssertTrue(note.waitForExistence(timeout: 3))
        note.press(forDuration: 1.0)
        app.buttons["Move to"].tap()
        app.buttons["Projects"].firstMatch.tap()
        // Closing the folder hides the note that moved into it.
        app.buttons["Projects"].tap()
        XCTAssertTrue(note.waitForNonExistence(timeout: 3))
        snapshot("3-moved")
    }
}
