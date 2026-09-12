import XCTest

@MainActor
final class TerminalUITests: XCTestCase {
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: AXID) -> XCUIElement {
        element(app, id.rawValue)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testSendingInputRendersInTerminal() {
        let app = launchedApp()

        let row = element(app, AXID.sessionRow("Fix login bug"))
        XCTAssertTrue(fastWait(row, timeout: 8))
        row.click()

        let terminal = element(app, AXID.terminalView("Fix login bug"))
        XCTAssertTrue(fastWait(terminal, timeout: 3))
        terminal.click()

        let probe = "echo-probe-\(UUID().uuidString.prefix(8))"
        app.typeText(probe)
        XCTAssertTrue(terminal.exists)
    }
}
