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
        let sessionsRadio = app.radioButtons["Sessions"].firstMatch
        if fastWait(sessionsRadio, timeout: 2) {
            sessionsRadio.click()
        } else {
            let sessionsButton = app.descendants(matching: .any)["Sidebar.AllSessions"].firstMatch
            if fastWait(sessionsButton, timeout: 2) {
                sessionsButton.click()
            }
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

        // The grid starts empty — membership is explicit, and nothing is a
        // member on a fresh launch — so it renders its empty state rather than
        // any tiles until sessions are actually assigned.
        let addAll = app.descendants(matching: .any)["Grid.AddAllButton"].firstMatch
        XCTAssertTrue(fastWait(addAll, timeout: 5), "grid toolbar controls should be present in grid presentation")
        addAll.click()

        let gridContainer = app.descendants(matching: .any)["GridView"].firstMatch
        XCTAssertTrue(fastWait(gridContainer, timeout: 5))

        // Each observed status reaches its tile as a label, not as colour
        // alone — the badge reports the status word to assistive technology.
        let expectedStatuses = [
            "Fix login bug": "Working",
            "General chat": "Waiting for Input",
            "Build pipeline error": "Crashed",
            "Code review assistant": "Ready for Review"
        ]
        for (title, expectedStatus) in expectedStatuses {
            let statusDot = app.descendants(matching: .any)["GridTile-\(title)-Status"].firstMatch
            XCTAssertTrue(fastWait(statusDot, timeout: 3), "missing status indicator for \(title)")
            XCTAssertEqual(statusDot.label, expectedStatus, "incorrect status for \(title)")
        }

        // A session with no observed status renders no badge at all — see
        // `StatusBadge`. Asserting this keeps "Unstarted" from silently
        // acquiring a dot that would read as a real state.
        let unobserved = app.descendants(matching: .any)["GridTile-Refactor sidebar-Status"].firstMatch
        XCTAssertFalse(unobserved.exists, "a session with no status should not render a status badge")

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
