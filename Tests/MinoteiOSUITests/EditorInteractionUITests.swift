import XCTest

/// Real taps and typing on the iOS editor: rendered Markdown must behave like
/// plain text with formatting (task boxes tick, bullets can be deleted, the
/// caret never lands inside hidden markup, Preview reads without editing).
@MainActor
final class EditorInteractionUITests: XCTestCase {
    private let seed = "- [ ] Task one\n- Bullet\nPlain [anchor](#end) text\n\n## End\n"
    private var app: XCUIApplication!

    // Layout of the iPhone editor (EditorTheme, MobileTextView): 17 pt IBM Plex
    // Mono, 27 pt lines, text inset 20 pt from the left, 16 pt from the top.
    private let left: CGFloat = 20
    private let top: CGFloat = 16
    private let lineHeight: CGFloat = 27
    private let characterWidth: CGFloat = 10.2

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["MINOTE_UITEST_NOTE"] = seed
        app.launch()
        let editor = app.textViews.firstMatch
        if !editor.waitForExistence(timeout: 3) {
            app.cells.firstMatch.tap()
        }
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
    }

    private var editor: XCUIElement { app.textViews.firstMatch }
    private var text: String { editor.value as? String ?? "" }
    private var keyboardIsUp: Bool { app.keyboards.count > 0 }

    /// A point on a line of the seed, `column` characters into the rendered text.
    private func point(line: Int, x: CGFloat) -> XCUICoordinate {
        editor.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: left + x, dy: top + CGFloat(line) * lineHeight + lineHeight / 2))
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTaskBoxesTickWithoutBringingUpTheKeyboard() {
        snapshot("1-rendered")
        point(line: 0, x: 7).tap()
        XCTAssertTrue(text.hasPrefix("- [x] Task one"), text)
        XCTAssertFalse(keyboardIsUp)
        point(line: 0, x: 7).tap()
        XCTAssertTrue(text.hasPrefix("- [ ] Task one"), text)
    }

    func testTappingABulletPutsTheCaretAfterItAndDeleteRemovesIt() {
        point(line: 1, x: 4).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        snapshot("2-editing-bullet")
        app.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(text.contains("\nBullet\n"), text)
        XCTAssertFalse(text.contains("- Bullet"), text)
        app.typeText("- ")
        XCTAssertTrue(text.contains("\n- Bullet\n"), text)
        snapshot("3-bullet-typed-back")
    }

    func testALinkTappedWhileTypingIsEditedNotOpened() {
        point(line: 1, x: 60).tap()                       // start editing
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        point(line: 2, x: 6 * characterWidth + 20).tap()  // inside "anchor"
        snapshot("4-link-revealed-while-editing")
        XCTAssertEqual(app.state, .runningForeground)      // nothing else opened
        app.typeText("X")
        XCTAssertTrue(text.contains("[an") && text.contains("X"), text)
    }

    func testPreviewReadsWithoutEditing() {
        point(line: 1, x: 60).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        togglePreview()
        let keyboardGone = expectation(for: NSPredicate(format: "count == 0"), evaluatedWith: app.keyboards)
        wait(for: [keyboardGone], timeout: 3)
        snapshot("5-preview")
        point(line: 1, x: 60).tap()
        XCTAssertFalse(keyboardIsUp)
        point(line: 0, x: 7).tap()                         // task boxes still tick
        XCTAssertTrue(text.hasPrefix("- [x] Task one"), text)
        togglePreview()
        point(line: 1, x: 60).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    }

    /// View menu ▸ Preview.
    private func togglePreview() {
        app.buttons["View"].firstMatch.tap()
        app.buttons["Preview"].firstMatch.tap()
    }
}
