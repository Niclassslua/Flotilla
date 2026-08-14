import XCTest

/// Covers Part 0's Grid View requirement: 3+ tiles independently
/// interactive on one screen, correct per-tile status, active-pane focus,
/// and navigation from a grid pane to the full session terminal. The 3
/// seeded fixture sessions provide the 3+ tiles.
@MainActor
final class GridViewUITests: XCTestCase {
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        return app
    }

    @discardableResult
    private func waitForTerminal(_ app: XCUIApplication, identifier: String, toContain text: String, timeout: TimeInterval = 8) -> Bool {
        let terminal = app.descendants(matching: .any)[identifier].firstMatch
        let predicate = NSPredicate { _, _ in
            (terminal.value as? String)?.contains(text) ?? false
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func switchToGrid(_ app: XCUIApplication) {
        let gridOption = app.radioButtons["Grid"]
        XCTAssertTrue(gridOption.waitForExistence(timeout: 8))
        gridOption.click()
    }

    func testGridShowsAllSessionsIndependentlyInteractive() {
        let app = launchedApp()
        switchToGrid(app)

        let gridContainer = app.descendants(matching: .any)["GridView"].firstMatch
        XCTAssertTrue(gridContainer.waitForExistence(timeout: 8))

        // All 3 fixture sessions' status dots are present in the grid.
        let expectedStatuses = [
            "Fix login bug": "Working",
            "Refactor sidebar": "Idle",
            "General chat": "Waiting for Input"
        ]
        for (title, expectedStatus) in expectedStatuses {
            let statusDot = app.descendants(matching: .any)["GridTile-\(title)-Status"].firstMatch
            XCTAssertTrue(statusDot.waitForExistence(timeout: 8), "missing status indicator for \(title)")
            XCTAssertEqual(statusDot.label, expectedStatus, "incorrect status for \(title)")
        }

        // Interact with two different tiles independently — each terminal
        // must receive only the input sent to it.
        let firstTerminal = app.descendants(matching: .any)["TerminalView-Fix login bug"].firstMatch
        XCTAssertTrue(firstTerminal.waitForExistence(timeout: 8))
        firstTerminal.click()
        let firstMarker = "grid-a-\(UUID().uuidString.prefix(8))"
        app.typeText(firstMarker)
        XCTAssertTrue(waitForTerminal(app, identifier: "TerminalView-Fix login bug", toContain: firstMarker))

        let secondTerminal = app.descendants(matching: .any)["TerminalView-Refactor sidebar"].firstMatch
        XCTAssertTrue(secondTerminal.waitForExistence(timeout: 8))
        secondTerminal.click()
        let secondMarker = "grid-b-\(UUID().uuidString.prefix(8))"
        app.typeText(secondMarker)
        XCTAssertTrue(waitForTerminal(app, identifier: "TerminalView-Refactor sidebar", toContain: secondMarker))

        // Cross-contamination check: session A's tile must not contain B's marker.
        let firstTerminalValue = app.descendants(matching: .any)["TerminalView-Fix login bug"].firstMatch.value as? String ?? ""
        XCTAssertFalse(firstTerminalValue.contains(secondMarker))
    }

    func testTileFocusOpensIndependentFullSessionTerminal() {
        let app = launchedApp()
        switchToGrid(app)

        let gridContainer = app.descendants(matching: .any)["GridView"].firstMatch
        XCTAssertTrue(gridContainer.waitForExistence(timeout: 8))

        let focusButton = app.descendants(matching: .any)["GridTile-Fix login bug-FocusButton"].firstMatch
        XCTAssertTrue(focusButton.waitForExistence(timeout: 8))
        focusButton.click()

        // Xirp's focus action leaves the grid and opens that session's
        // independent full-size terminal renderer.
        let focusedTerminal = app.descendants(matching: .any)["TerminalView-Fix login bug"].firstMatch
        XCTAssertTrue(focusedTerminal.waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["GridView"].firstMatch.exists)

        // Returning to Grid remounts the grid renderer rather than scaling
        // or reparenting the full-size renderer.
        app.radioButtons["Grid"].click()
        XCTAssertTrue(app.descendants(matching: .any)["GridView"].firstMatch.waitForExistence(timeout: 8))
    }
}
