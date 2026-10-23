import XCTest

@MainActor
final class DiffAndFilesUITests: XCTestCase {
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

    func testDiffPanelAndFileBrowser() {
        let app = launchedApp()
        let sessionRow = element(app, AXID.sessionRow("Refactor sidebar"))
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 8))
        sessionRow.click()

        // 1. Rail Git opens project history; Changes sub-tab hosts DiffPanel.
        let gitRail = element(app, "ProjectToolRail.Git")
        XCTAssertTrue(gitRail.waitForExistence(timeout: 3))
        gitRail.click()

        let changesSubTab = element(app, "ProjectGit.SubTab-Changes")
        XCTAssertTrue(changesSubTab.waitForExistence(timeout: 5))
        changesSubTab.click()

        let emptyState = element(app, .diffPanelEmpty)
        let populatedState = element(app, .diffPanelList)
        let panelOpened = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in emptyState.exists || populatedState.exists },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [panelOpened], timeout: 8),
            .completed,
            "the project Changes panel should open in one of its resting states"
        )

        let simulateEditButton = element(app, .diffPanelSimulateEditButton)
        XCTAssertTrue(simulateEditButton.waitForExistence(timeout: 3))
        simulateEditButton.click()

        let changedFile = element(app, AXID.diffPanelFile("README.md"))
        XCTAssertTrue(changedFile.waitForExistence(timeout: 3))

        let refreshButton = element(app, .diffPanelRefreshButton)
        XCTAssertTrue(refreshButton.waitForExistence(timeout: 3))
        refreshButton.click()
        XCTAssertTrue(element(app, AXID.diffPanelFile("README.md")).waitForExistence(timeout: 3))

        // 2. Files via the project tool rail (replaces the session folder button).
        let filesRail = element(app, "ProjectToolRail.Files")
        XCTAssertTrue(filesRail.waitForExistence(timeout: 3))
        filesRail.click()

        let readmeRow = element(app, AXID.fileBrowserRow("README.md"))
        XCTAssertTrue(readmeRow.waitForExistence(timeout: 3))
    }
}
