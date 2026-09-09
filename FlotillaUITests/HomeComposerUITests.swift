import XCTest

/// Covers the home dashboard's always-visible composer (`LaunchpadDesign`),
/// which replaced `SessionLaunchForm`. Unlike the modal launcher
/// (`CreateSessionUITests`), this one requires a non-empty goal — it never
/// leaves the screen, so a stray ⌘↩ is far easier to trigger by accident.
///
/// "Launch & Open" navigates the app to the new session; "Launch & Stay Here"
/// must leave the app on Home. That split is driven by `selectAfterCreating`,
/// which `SessionDraft.launch(opensSession:)` forwards to
/// `AppStore.createSession` — `testLaunchAndStayHereKeepsHomeOnScreen` guards
/// it, since it is easy to silently regress back to an unconditional select.
/// See `SessionDraftTests.testClearGoalOnlyTouchesTheGoal` for the goal-reset
/// behaviour itself, unit-tested in isolation.
@MainActor
final class HomeComposerUITests: XCTestCase {
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

    func testEmptyGoalDisablesLaunch() {
        let app = launchedApp()

        let launchButton = element(app, "Home.LaunchButton")
        XCTAssertTrue(fastWait(launchButton, timeout: 8))
        XCTAssertFalse(launchButton.isEnabled, "The home composer must require an objective before launching")
    }

    func testLaunchGeneralSessionFromHome() {
        let app = launchedApp()

        let goalField = element(app, "Home.GoalField")
        XCTAssertTrue(fastWait(goalField, timeout: 8))
        goalField.click()
        goalField.typeText("Investigate the flaky teardown")

        let launchButton = element(app, "Home.LaunchButton")
        XCTAssertTrue(launchButton.isEnabled)
        launchButton.click()

        XCTAssertTrue(fastWait(element(app, "SessionRow-Investigate the flaky teardown"), timeout: 5))
    }

    func testLaunchAndStayHereKeepsHomeOnScreen() {
        let app = launchedApp()

        let goalField = element(app, "Home.GoalField")
        XCTAssertTrue(fastWait(goalField, timeout: 8))
        goalField.click()
        goalField.typeText("Draft the migration notes")

        let stayButton = element(app, "Home.BackgroundButton")
        XCTAssertTrue(stayButton.isEnabled)
        stayButton.click()

        // The session is created...
        XCTAssertTrue(fastWait(element(app, "SessionRow-Draft the migration notes"), timeout: 5))
        // ...but the app stays on Home rather than following it into the detail column.
        XCTAssertTrue(element(app, "Home.GoalField").exists,
                      "\"Launch & Stay Here\" must not navigate away from the Home dashboard")
    }
}
