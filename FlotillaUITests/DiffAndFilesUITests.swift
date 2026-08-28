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
        let sessionsRadio = app.radioButtons["Sessions"].firstMatch
        if sessionsRadio.waitForExistence(timeout: 2) {
            sessionsRadio.click()
        } else {
            let sessionsButton = app.descendants(matching: .any)["Sidebar.AllSessions"].firstMatch
            if sessionsButton.waitForExistence(timeout: 2) {
                sessionsButton.click()
            }
        }
        let sessionRow = app.descendants(matching: .any)["SessionRow-Refactor sidebar"].firstMatch
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 8))
        sessionRow.click()

        // 1. Test Diff panel via the toolbar's "Git Changes" jump, scoped to this session's worktree
        let openGitButton = app.descendants(matching: .any)["Toolbar.OpenProjectGit"].firstMatch
        XCTAssertTrue(openGitButton.waitForExistence(timeout: 3))
        openGitButton.click()

        // Longer timeout than the other checks: navigating here now goes
        // through the project's worktree resolution first, which is slower
        // than the old in-place lens swap was.
        let emptyState = app.descendants(matching: .any)["DiffPanel.Empty"].firstMatch
        XCTAssertTrue(emptyState.waitForExistence(timeout: 6))

        let simulateEditButton = app.descendants(matching: .any)["DiffPanel.SimulateEditButton"].firstMatch
        XCTAssertTrue(simulateEditButton.waitForExistence(timeout: 3))
        simulateEditButton.click()

        let changedFile = app.descendants(matching: .any)["DiffPanel.File-README.md"].firstMatch
        XCTAssertTrue(changedFile.waitForExistence(timeout: 3))

        let refreshButton = app.descendants(matching: .any)["DiffPanel.RefreshButton"].firstMatch
        XCTAssertTrue(refreshButton.waitForExistence(timeout: 3))
        refreshButton.click()
        XCTAssertTrue(app.descendants(matching: .any)["DiffPanel.File-README.md"].firstMatch.waitForExistence(timeout: 3))

        // 2. Test Files panel via the sidebar session row, then the toolbar's "File Browser" jump.
        // Reviewing changes above navigated away to the project's Git tab, so
        // get back to the session the same way a user would: through the sidebar.
        if sessionsRadio.waitForExistence(timeout: 2) {
            sessionsRadio.click()
        }
        let secondSessionRow = app.descendants(matching: .any)["SessionRow-Refactor sidebar"].firstMatch
        XCTAssertTrue(secondSessionRow.waitForExistence(timeout: 3))
        secondSessionRow.click()

        let openFilesButton = app.descendants(matching: .any)["Toolbar.OpenProjectFiles"].firstMatch
        XCTAssertTrue(openFilesButton.waitForExistence(timeout: 3))
        openFilesButton.click()

        let readmeRow = app.descendants(matching: .any)["FileBrowser.Row-README.md"].firstMatch
        XCTAssertTrue(readmeRow.waitForExistence(timeout: 3))
    }
}
