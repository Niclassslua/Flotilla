import XCTest

/// Covers Part 0's diff panel and file browser requirements. Both use the
/// real `GitService` against the app-managed fixture repo at
/// `AppEnvironment.uiTestFixtureProjectPath` (reset fresh on every app
/// launch) — see `DiffPanelView.simulateEdit()` for why the file edit is
/// triggered through an in-app button rather than the test process writing
/// the file directly (the XCUITest runner is sandboxed read-only outside
/// its own container).
@MainActor
final class DiffAndFilesUITests: XCTestCase {
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        return app
    }

    /// Creates a main-checkout project session against the fixture repo and
    /// selects it, leaving the app on the Terminal panel.
    private func createFixtureProjectSession(_ app: XCUIApplication, goal: String) {
        let newSessionButton = app.descendants(matching: .any)["NewSessionButton"].firstMatch
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 8))
        newSessionButton.click()

        let projectFolderOption = app.radioButtons["Project Folder"]
        XCTAssertTrue(projectFolderOption.waitForExistence(timeout: 8))
        projectFolderOption.click()

        let chooseFolderButton = app.descendants(matching: .any)["CreateSession.ChooseFolderButton"].firstMatch
        XCTAssertTrue(chooseFolderButton.waitForExistence(timeout: 8))
        chooseFolderButton.click()

        let goalField = app.descendants(matching: .any)["CreateSession.GoalField"].firstMatch
        XCTAssertTrue(goalField.waitForExistence(timeout: 8))
        goalField.click()
        goalField.typeText(goal)

        let createButton = app.descendants(matching: .any)["CreateSession.CreateButton"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 8))
        createButton.click()

        let row = app.descendants(matching: .any)["SessionRow-\(goal)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
    }

    private func selectPanel(_ app: XCUIApplication, label: String) {
        let command = switch label {
        case "Diff": "Review changes"
        case "Files": "Browse project files"
        default: label
        }

        let paletteButton = app.descendants(matching: .any)["CommandPaletteButton"].firstMatch
        XCTAssertTrue(paletteButton.waitForExistence(timeout: 8))
        paletteButton.click()

        let search = app.descendants(matching: .any)["CommandPalette.Search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.click()
        search.typeText(command)

        let row = app.descendants(matching: .any)["CommandPalette.Row-\(command)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "missing \(label) panel command")
        row.click()
    }

    func testDiffPanelUpdatesAfterFileEdit() {
        let app = launchedApp()
        createFixtureProjectSession(app, goal: "Diff panel test session")

        selectPanel(app, label: "Diff")

        // Fresh fixture repo has no uncommitted changes yet.
        let emptyState = app.descendants(matching: .any)["DiffPanel.Empty"].firstMatch
        XCTAssertTrue(emptyState.waitForExistence(timeout: 8))

        let simulateEditButton = app.descendants(matching: .any)["DiffPanel.SimulateEditButton"].firstMatch
        XCTAssertTrue(simulateEditButton.waitForExistence(timeout: 8))
        simulateEditButton.click()

        // The edit should show up as a changed README.md without needing a
        // manual refresh (simulateEdit refreshes itself), but also confirm
        // the explicit Refresh control works.
        let changedFile = app.descendants(matching: .any)["DiffPanel.File-README.md"].firstMatch
        XCTAssertTrue(changedFile.waitForExistence(timeout: 8))

        let refreshButton = app.descendants(matching: .any)["DiffPanel.RefreshButton"].firstMatch
        XCTAssertTrue(refreshButton.waitForExistence(timeout: 8))
        refreshButton.click()
        XCTAssertTrue(app.descendants(matching: .any)["DiffPanel.File-README.md"].firstMatch.waitForExistence(timeout: 8))
    }

    func testFileBrowserShowsWorktreeContents() {
        let app = launchedApp()
        createFixtureProjectSession(app, goal: "File browser test session")

        selectPanel(app, label: "Files")

        let readmeRow = app.descendants(matching: .any)["FileBrowser.Row-README.md"].firstMatch
        XCTAssertTrue(readmeRow.waitForExistence(timeout: 8))
    }
}
