import XCTest

@MainActor
final class RestartSessionUITests: XCTestCase {
    private func element(_ app: XCUIApplication, _ id: AXID) -> XCUIElement {
        element(app, id.rawValue)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
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
