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
        let sessionsRadio = app.radioButtons["Sessions"].firstMatch
        if sessionsRadio.waitForExistence(timeout: 2) {
            sessionsRadio.click()
        } else {
            let sessionsButton = element(app, .sidebarAllSessions)
            if sessionsButton.waitForExistence(timeout: 2) {
                sessionsButton.click()
            }
        }
        let sessionRow = element(app, AXID.sessionRow("Refactor sidebar"))
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 8))
        sessionRow.click()

        // 1. Test Diff panel via View > Changes, scoped to this session's
        // worktree. The session bar's Git button is gone, so the menu's
        // keyboard shortcut is now the entry point this covers.
        let filesButton = element(app, .toolbarOpenProjectFiles)
        XCTAssertTrue(filesButton.waitForExistence(timeout: 3))
        app.typeKey("g", modifierFlags: [.command, .shift])

        // Longer timeout than the other checks: navigating here now goes
        // through the project's worktree resolution first, which is slower
        // than the old in-place lens swap was.
        //
        // Either resting state counts. `simulateEditForAutomation` below
        // writes to the fixture checkout's README and nothing reverts it, so
        // whether this run starts on a clean tree depends on whether a
        // previous run finished. Asserting specifically on "No Changes" made
        // the test pass or fail on leftover state rather than on the panel.
        let emptyState = element(app, .diffPanelEmpty)
        let populatedState = element(app, .diffPanelList)
        let panelOpened = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in emptyState.exists || populatedState.exists },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [panelOpened], timeout: 8),
            .completed,
            "the diff panel should open in one of its resting states"
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

        // 2. Test Files panel via the sidebar session row, then the toolbar's "File Browser" jump.
        // Reviewing changes above navigated away to the project's Git tab, so
        // get back to the session the same way a user would: through the sidebar.
        if sessionsRadio.waitForExistence(timeout: 2) {
            sessionsRadio.click()
        }
        let secondSessionRow = element(app, AXID.sessionRow("Refactor sidebar"))
        XCTAssertTrue(secondSessionRow.waitForExistence(timeout: 3))
        secondSessionRow.click()

        let openFilesButton = element(app, .toolbarOpenProjectFiles)
        XCTAssertTrue(openFilesButton.waitForExistence(timeout: 3))
        openFilesButton.click()

        let readmeRow = element(app, AXID.fileBrowserRow("README.md"))
        XCTAssertTrue(readmeRow.waitForExistence(timeout: 3))
    }
}
