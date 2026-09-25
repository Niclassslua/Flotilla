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

    private func element(_ app: XCUIApplication, _ id: AXID) -> XCUIElement {
        element(app, id.rawValue)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testKanbanBoardColumnsContextMenuAndOpenSession() {
        let app = launchedApp()

        // The global bar's Board button is a destination: it selects
        // Sessions and the board presentation in one click, from anywhere.
        let boardButton = element(app, .toolbarShowBoard)
        XCTAssertTrue(boardButton.waitForExistence(timeout: 5), "the global bar should always offer Board")
        boardButton.click()

        let kanbanView = element(app, .kanbanBoard)
        XCTAssertTrue(kanbanView.waitForExistence(timeout: 8))

        // All kanban columns are rendered
        // Matches `KanbanColumn.defaultStatusColumns()`. "Idle" and
        // "Finished" were folded into Ready for Review when
        // SessionStatus collapsed to four cases in a5482d3.
        for title in ["Working", "Waiting", "Ready for Review", "Crashed"] {
            let columnHeader = element(app, AXID.kanbanColumnHeader(title))
            XCTAssertTrue(columnHeader.waitForExistence(timeout: 3), "missing header for \(title)")
        }

        // Context menu & open action
        let card = element(app, AXID.kanbanCard("Fix login bug"))
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        // The card is an accessibility container, so a plain `rightClick()` can
        // land on a child that consumes it. Aiming at the card's own centre
        // opens the menu reliably.
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()

        let openItem = element(app, .openSessionButton)
        XCTAssertTrue(openItem.waitForExistence(timeout: 3))
        let restartItem = element(app, .restartSessionButton)
        XCTAssertTrue(restartItem.waitForExistence(timeout: 3))

        openItem.click()
        // Confirms navigation actually landed on a focused session (this
        // toolbar button only renders in session scope), not just any window.
        let sessionToolbar = element(app, .toolbarOpenProjectFiles)
        XCTAssertTrue(sessionToolbar.waitForExistence(timeout: 5))
    }
}
