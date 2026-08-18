import XCTest

@MainActor
final class HooksUITests: XCTestCase {
    func testSimulatedWaitingForInputFiresNotification() {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launchEnvironment["UI_TESTING_SIMULATE_WAITING_SESSION"] = "General chat"
        app.launch()

        let sessionRow = app.descendants(matching: .any)["SessionRow-General chat"].firstMatch
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 8))

        let statusIndicator = app.descendants(matching: .any)["SessionRow-General chat-Status"].firstMatch
        XCTAssertTrue(statusIndicator.waitForExistence(timeout: 3))
        XCTAssertEqual(statusIndicator.label, "Waiting for Input")
    }
}
