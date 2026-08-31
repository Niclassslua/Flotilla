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

        // The global bar's Board button is a destination: it selects
        // Sessions and the board presentation in one click, from anywhere.
        let boardButton = app.descendants(matching: .any)["Toolbar.ShowBoard"].firstMatch
        XCTAssertTrue(boardButton.waitForExistence(timeout: 5), "the global bar should always offer Board")
        boardButton.click()

        let kanbanView = app.descendants(matching: .any)["KanbanBoard"].firstMatch
        XCTAssertTrue(kanbanView.waitForExistence(timeout: 8))

        // All kanban columns are rendered
        // Matches `KanbanColumn.defaultStatusColumns()`. "Idle" and
        // "Finished" were folded into Unstarted/Ready for Review when
        // SessionStatus collapsed to four cases in a5482d3.
        for title in ["Unstarted", "Working", "Waiting", "Ready for Review", "Crashed"] {
            let columnHeader = app.descendants(matching: .any)["KanbanColumn-\(title)-Header"].firstMatch
            XCTAssertTrue(columnHeader.waitForExistence(timeout: 3), "missing header for \(title)")
        }

        // Context menu & open action
        let card = app.descendants(matching: .any)["KanbanCard-Fix login bug"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        // The card is an accessibility container, so a plain `rightClick()` can
        // land on a child that consumes it. Aiming at the card's own centre
        // opens the menu reliably.
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()

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
