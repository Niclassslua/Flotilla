import XCTest

/// `CreateSessionView` and `CommandPaletteView` used to be genuine macOS
/// `.sheet`s — modal to the window, and clicking outside them is inert by
/// design there, not a bug. `FlotillaShell` now renders both as an in-window
/// overlay instead (a dimmed scrim behind a floating card), specifically so
/// they can behave like Spotlight: dismissible by clicking outside or
/// pressing Escape.
///
/// Only click-outside is covered here. Escape dismissal (via `.onKeyPress`
/// on each field, `.onExitCommand`, and `EscapeKeyCatcher`'s local
/// `NSEvent` monitor as a last resort against a focused text field
/// swallowing the key first) was verified manually, repeatedly, with a
/// genuine keystroke: `osascript -e 'tell application "System Events" to
/// keystroke (ASCII character 27)'` against a running debug build. It is
/// deliberately not automated here — `XCUIElement.typeKey(.escape, ...)`
/// and even a raw `CGEvent` posted directly from the test process never
/// reach the app in this environment (neither does `key code 53` via
/// `osascript`, while `keystroke (ASCII character 27)` does), which looks
/// like a TCC/Accessibility permission gap specific to how this sandbox
/// authorizes synthetic keyboard injection — not a defect in the feature.
/// A test that can never exercise the real code path would only produce
/// false failures.
@MainActor
final class OverlayDismissalUITests: XCTestCase {
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// The home composer's launch button sits behind both overlays at a known,
    /// stable location — clicking it only succeeds if the scrim isn't actually
    /// intercepting hits.
    private func clickBehindOverlay(_ app: XCUIApplication) {
        let homeLaunchButton = element(app, "Home.LaunchButton")
        XCTAssertTrue(homeLaunchButton.exists)
        homeLaunchButton.click()
    }

    func testClickOutsideDismissesCreateSessionModal() {
        let app = launchedApp()
        XCTAssertTrue(element(app, "NewSessionButton").waitForExistence(timeout: 8))
        element(app, "NewSessionButton").click()

        let goalField = element(app, "CreateSession.GoalField")
        XCTAssertTrue(goalField.waitForExistence(timeout: 3))

        clickBehindOverlay(app)
        XCTAssertTrue(goalField.waitForNonExistence(timeout: 3))
    }

    func testClickOutsideDismissesCommandPalette() {
        let app = launchedApp()
        XCTAssertTrue(element(app, "Toolbar.CommandPalette").waitForExistence(timeout: 8))
        element(app, "Toolbar.CommandPalette").click()

        // Opening the palette is occasionally slow in this environment —
        // a longer budget than the toolbar button's own.
        let search = element(app, "CommandPalette.Search")
        XCTAssertTrue(search.waitForExistence(timeout: 15))

        clickBehindOverlay(app)
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
    }

    func testClickInsideCreateSessionModalDoesNotDismiss() {
        let app = launchedApp()
        XCTAssertTrue(element(app, "NewSessionButton").waitForExistence(timeout: 8))
        element(app, "NewSessionButton").click()

        let goalField = element(app, "CreateSession.GoalField")
        XCTAssertTrue(goalField.waitForExistence(timeout: 3))

        let summary = element(app, "CreateSession.LaunchSummary")
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        summary.click()

        // Card should remain open after clicking inside the card
        XCTAssertTrue(goalField.exists)
    }
}
