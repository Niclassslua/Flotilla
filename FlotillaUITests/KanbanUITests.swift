import XCTest

@MainActor
final class KanbanUITests: XCTestCase {
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        return app
    }

    func testKanbanBoardColumnsContextMenuAndOpenSession() {
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

        let boardButton = app.descendants(matching: .any)["Toolbar.PresentationPicker"].buttons["Board"].firstMatch
        if boardButton.waitForExistence(timeout: 3) {
            boardButton.click()
        } else {
            let legacyBoard = app.radioButtons["Board"]
            if legacyBoard.waitForExistence(timeout: 3) { legacyBoard.click() }
        }

        let kanbanView = app.descendants(matching: .any)["KanbanBoard"].firstMatch
        XCTAssertTrue(kanbanView.waitForExistence(timeout: 8))

        // All kanban columns are rendered
        for title in ["Working", "Waiting", "Idle", "Finished"] {
            let columnHeader = app.descendants(matching: .any)["KanbanColumn-\(title)-Header"].firstMatch
            XCTAssertTrue(columnHeader.waitForExistence(timeout: 3), "missing header for \(title)")
        }

        // Context menu & open action
        let card = app.descendants(matching: .any)["KanbanCard-Fix login bug"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        card.rightClick()

        let openItem = app.descendants(matching: .any)["Open Session"].firstMatch
        XCTAssertTrue(openItem.waitForExistence(timeout: 3))
        let restartItem = app.descendants(matching: .any)["Restart Session"].firstMatch
        XCTAssertTrue(restartItem.waitForExistence(timeout: 3))

        openItem.click()
        // Confirms navigation actually landed on a focused session (this
        // toolbar button only renders in session scope), not just any window.
        let sessionToolbar = app.descendants(matching: .any)["Toolbar.OpenProjectGit"].firstMatch
        XCTAssertTrue(sessionToolbar.waitForExistence(timeout: 5))
    }
}
