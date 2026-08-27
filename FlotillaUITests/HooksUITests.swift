import XCTest

@MainActor
final class HooksUITests: XCTestCase {
    func testSimulatedPermissionPromptDisplaysActionableStatus() {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launchEnvironment["UI_TESTING_SIMULATE_WAITING_SESSION"] = "General chat"
        app.launch()

        let allSessions = app.buttons["Sidebar.AllSessions"]
        XCTAssertTrue(allSessions.waitForExistence(timeout: 8))
        allSessions.click()

        let sessionRow = app.descendants(matching: .any)["SessionRow-General chat"].firstMatch
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 8))

        let rowButton = sessionRow.buttons.firstMatch
        XCTAssertTrue(rowButton.waitForExistence(timeout: 3))
        XCTAssertTrue(rowButton.label.contains("Needs Permission"))
    }
}
