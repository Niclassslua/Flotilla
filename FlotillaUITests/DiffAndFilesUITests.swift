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

    func testDiffPanelAndFileBrowser() {
        let app = launchedApp()
        let sessionRow = app.descendants(matching: .any)["SessionRow-Refactor sidebar"].firstMatch
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 8))
        sessionRow.click()

        // 1. Test Diff panel via Inspector toggle
        let inspectorToggle = app.descendants(matching: .any)["Toolbar.InspectorToggle"].firstMatch
        XCTAssertTrue(inspectorToggle.waitForExistence(timeout: 3))
        inspectorToggle.click()

        let emptyState = app.descendants(matching: .any)["DiffPanel.Empty"].firstMatch
        XCTAssertTrue(emptyState.waitForExistence(timeout: 3))

        let simulateEditButton = app.descendants(matching: .any)["DiffPanel.SimulateEditButton"].firstMatch
        XCTAssertTrue(simulateEditButton.waitForExistence(timeout: 3))
        simulateEditButton.click()

        let changedFile = app.descendants(matching: .any)["DiffPanel.File-README.md"].firstMatch
        XCTAssertTrue(changedFile.waitForExistence(timeout: 3))

        let refreshButton = app.descendants(matching: .any)["DiffPanel.RefreshButton"].firstMatch
        XCTAssertTrue(refreshButton.waitForExistence(timeout: 3))
        refreshButton.click()
        XCTAssertTrue(app.descendants(matching: .any)["DiffPanel.File-README.md"].firstMatch.waitForExistence(timeout: 3))

        // 2. Test Files panel via Inspector Files tab
        let filesTab = app.radioButtons["Files"]
        XCTAssertTrue(filesTab.waitForExistence(timeout: 3))
        filesTab.click()

        let readmeRow = app.descendants(matching: .any)["FileBrowser.Row-README.md"].firstMatch
        XCTAssertTrue(readmeRow.waitForExistence(timeout: 3))
    }
}
