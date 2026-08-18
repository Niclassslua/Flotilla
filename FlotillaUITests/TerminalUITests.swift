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

    func testSendingInputRendersInTerminal() {
        let app = launchedApp()

        let row = app.descendants(matching: .any)["SessionRow-Fix login bug"].firstMatch
        XCTAssertTrue(fastWait(row, timeout: 8))
        row.click()

        let terminal = app.descendants(matching: .any)["TerminalView-Fix login bug"].firstMatch
        XCTAssertTrue(fastWait(terminal, timeout: 3))
        terminal.click()

        let probe = "echo-probe-\(UUID().uuidString.prefix(8))"
        app.typeText(probe)
        XCTAssertTrue(terminal.exists)
    }
}
