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

    private func element(_ app: XCUIApplication, _ id: AXID) -> XCUIElement {
        element(app, id.rawValue)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// One click now: the global bar's Grid button is a destination, so it
    /// selects Sessions and the grid presentation together. It replaced the
    /// segmented picker, which had to be preceded by selecting Sessions
    /// because the picker was hidden everywhere else.
    private func switchToGrid(_ app: XCUIApplication) {
        let gridButton = element(app, .toolbarShowGrid)
        XCTAssertTrue(fastWait(gridButton, timeout: 5), "the global bar should always offer Grid")
        gridButton.click()
    }

    /// The Grid button is a toggle: pressing it while the grid is already on
    /// screen drops back to the single-session Focus view. Before this there
    /// was no way out of the grid from the same control that entered it.
    func testGridButtonTogglesGridOff() {
        let app = launchedApp()
        switchToGrid(app)

        let gridContainer = element(app, .gridView)
        let emptyState = element(app, .gridEmptyState)
        let gridVisible = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in emptyState.exists || gridContainer.exists },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [gridVisible], timeout: 5),
            .completed,
            "first press should show the grid"
        )

        let gridButton = element(app, .toolbarShowGrid)
        gridButton.click()

        XCTAssertTrue(gridContainer.waitForNonExistence(timeout: 5))
        XCTAssertTrue(emptyState.waitForNonExistence(timeout: 5), "second press should leave the grid")
    }

    func testGridInteractionAndTileFocus() {
        let app = launchedApp()
        switchToGrid(app)

        // The grid starts empty — membership is explicit, and nothing is a
        // member on a fresh launch — so it renders its empty state rather than
        // any tiles until sessions are actually assigned.
        let addAll = element(app, .gridAddAllButton)
        XCTAssertTrue(fastWait(addAll, timeout: 5), "grid toolbar controls should be present in grid presentation")
        addAll.click()

        let gridContainer = element(app, .gridView)
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
            let statusDot = element(app, AXID.gridTileStatus(title))
            XCTAssertTrue(fastWait(statusDot, timeout: 3), "missing status indicator for \(title)")
            XCTAssertEqual(statusDot.label, expectedStatus, "incorrect status for \(title)")
        }

        // A session with no observed status renders no badge at all — see
        // `StatusBadge`. Asserting this keeps "Unstarted" from silently
        // acquiring a dot that would read as a real state.
        let unobserved = element(app, AXID.gridTileStatus("Refactor sidebar"))
        XCTAssertFalse(unobserved.exists, "a session with no status should not render a status badge")

        // Test tile focus action: leaves the grid and opens full-size terminal renderer.
        let focusButton = element(app, AXID.gridTileFocusButton("Fix login bug"))
        if fastWait(focusButton, timeout: 3) {
            focusButton.click()
            let focusedTerminal = element(app, AXID.terminalView("Fix login bug"))
            XCTAssertTrue(fastWait(focusedTerminal, timeout: 3))
            XCTAssertFalse(element(app, .gridView).exists)
        }
    }
}
