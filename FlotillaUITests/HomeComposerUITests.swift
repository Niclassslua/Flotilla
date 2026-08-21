import XCTest

/// Covers the home dashboard's always-visible composer (`LaunchpadDesign`),
/// which replaced `SessionLaunchForm`. Unlike the modal launcher
/// (`CreateSessionUITests`), this one requires a non-empty goal — it never
/// leaves the screen, so a stray ⌘↩ is far easier to trigger by accident.
///
/// Note: creating *any* session — foreground or background — navigates the
/// whole app away from Home, because `AppStore.createSession` unconditionally
/// sets `selectedSessionID`, which `FlotillaShell` observes and follows. That
/// is existing app behaviour, not specific to this composer, so these tests
/// don't assert on staying on the Home screen after a launch — see
/// `SessionDraftTests.testClearGoalOnlyTouchesTheGoal` for the goal-reset
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
}
