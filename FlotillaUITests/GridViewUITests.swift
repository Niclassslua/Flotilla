import XCTest

@MainActor
final class GridViewUITests: XCTestCase {
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        return app
    }

    private func switchToGrid(_ app: XCUIApplication) {
        let sessionsButton = app.descendants(matching: .any)["Sidebar.AllSessions"].firstMatch
        if fastWait(sessionsButton, timeout: 3) {
            sessionsButton.click()
        }
        let gridButton = app.descendants(matching: .any)["Toolbar.PresentationPicker"].buttons["Grid"].firstMatch
        if fastWait(gridButton, timeout: 3) {
            gridButton.click()
        } else {
            let legacyGrid = app.radioButtons["Grid"]
            if fastWait(legacyGrid, timeout: 3) {
                legacyGrid.click()
            }
        }
    }

    func testGridInteractionAndTileFocus() {
        let app = launchedApp()
        switchToGrid(app)

        let gridContainer = app.descendants(matching: .any)["GridView"].firstMatch
        XCTAssertTrue(fastWait(gridContainer, timeout: 5))

        // All 3 fixture sessions' status dots are present in the grid.
        let expectedStatuses = [
            "Fix login bug": "Working",
            "Refactor sidebar": "Idle",
            "General chat": "Waiting for Input"
        ]
        for (title, expectedStatus) in expectedStatuses {
            let statusDot = app.descendants(matching: .any)["GridTile-\(title)-Status"].firstMatch
            XCTAssertTrue(fastWait(statusDot, timeout: 3), "missing status indicator for \(title)")
            XCTAssertEqual(statusDot.label, expectedStatus, "incorrect status for \(title)")
        }

        // Test tile focus action: leaves the grid and opens full-size terminal renderer.
        let focusButton = app.descendants(matching: .any)["GridTile-Fix login bug-FocusButton"].firstMatch
        if fastWait(focusButton, timeout: 3) {
            focusButton.click()
            let focusedTerminal = app.descendants(matching: .any)["TerminalView-Fix login bug"].firstMatch
            XCTAssertTrue(fastWait(focusedTerminal, timeout: 3))
            XCTAssertFalse(app.descendants(matching: .any)["GridView"].firstMatch.exists)
        }
    }
}
