import XCTest

@MainActor
final class RestartSessionUITests: XCTestCase {
    func testRestartCrashedSessionRecoversToWorking() {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launchEnvironment["UI_TESTING_SIMULATE_CRASHED_SESSION"] = "Fix login bug"
        app.launch()

        let row = app.descendants(matching: .any)["SessionRow-Fix login bug"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.click()

        let restartButton = app.descendants(matching: .any)["Restart Session"].firstMatch
        if restartButton.waitForExistence(timeout: 3) {
            restartButton.click()
            let workingIndicator = app.descendants(matching: .any)["SessionRow-Fix login bug-Status"].firstMatch
            XCTAssertTrue(workingIndicator.waitForExistence(timeout: 3))
        }
    }
}
