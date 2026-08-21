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
        let sessionsButton = app.descendants(matching: .any)["Sidebar.AllSessions"].firstMatch
        if sessionsButton.waitForExistence(timeout: 3) {
            sessionsButton.click()
        }
        let sessionRow = app.descendants(matching: .any)["SessionRow-Refactor sidebar"].firstMatch
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 8))
        sessionRow.click()

        // 1. Test Diff panel via Changes lens
        let changesLens = app.descendants(matching: .any)["Session.Lens.changes"].firstMatch
        XCTAssertTrue(changesLens.waitForExistence(timeout: 3))
        changesLens.click()

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

        // 2. Test Files panel via Files lens
        let filesLens = app.descendants(matching: .any)["Session.Lens.files"].firstMatch
        XCTAssertTrue(filesLens.waitForExistence(timeout: 3))
        filesLens.click()

        let readmeRow = app.descendants(matching: .any)["FileBrowser.Row-README.md"].firstMatch
        XCTAssertTrue(readmeRow.waitForExistence(timeout: 3))
    }
}
