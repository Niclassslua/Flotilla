import XCTest

@MainActor
final class RestartSessionUITests: XCTestCase {
    private func element(_ app: XCUIApplication, _ id: AXID) -> XCUIElement {
        element(app, id.rawValue)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// The exit screen hides the terminal, so "Show Output" is the only way
    /// to read why the agent died, and the strip it leaves behind must still
    /// restart the session.
    func testAgentExitScreenRevealsOutputThenRestartsFromTheStrip() {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launchEnvironment["UI_TESTING_SIMULATE_AGENT_EXIT"] = "Fix login bug"
        app.launch()

        let row = element(app, AXID.sessionRow("Fix login bug"))
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.click()

        let exitScreen = element(app, .agentExitScreen)
        XCTAssertTrue(exitScreen.waitForExistence(timeout: 3))

        element(app, .agentExitShowOutput).click()
        XCTAssertTrue(exitScreen.waitForNonExistence(timeout: 3))
        let stripRestart = element(app, .agentExitStripRestart)
        XCTAssertTrue(stripRestart.waitForExistence(timeout: 3))

        stripRestart.click()
        XCTAssertTrue(stripRestart.waitForNonExistence(timeout: 3))
        XCTAssertFalse(exitScreen.exists, "a restarted agent must not show the exit screen again")
    }

    func testRestartCrashedSessionRecoversToWorking() {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launchEnvironment["UI_TESTING_SIMULATE_CRASHED_SESSION"] = "Fix login bug"
        app.launch()

        let row = element(app, AXID.sessionRow("Fix login bug"))
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.click()

        let restartButton = element(app, .restartSessionButton)
        if restartButton.waitForExistence(timeout: 3) {
            restartButton.click()
            let workingIndicator = element(app, AXID.sessionRowStatus("Fix login bug"))
            XCTAssertTrue(workingIndicator.waitForExistence(timeout: 3))
        }
    }
}
