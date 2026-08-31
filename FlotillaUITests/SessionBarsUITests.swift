import XCTest

/// The two bars added below the global bar: the session group bar in Sessions,
/// and the session bar on every tile and on the focused session.
///
/// Both assertions here are the kind a human cannot eyeball: a group chip that
/// stops filtering, or a rename that types into the field and never reaches
/// the store, both look completely correct in a screenshot.
@MainActor
final class SessionBarsUITests: XCTestCase {

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func showGrid(_ app: XCUIApplication) {
        let grid = element(app, "Toolbar.ShowGrid")
        XCTAssertTrue(fastWait(grid, timeout: 5))
        grid.click()
    }

    /// The seeded fleet is one project ("Flotilla", four sessions) plus two
    /// sessions with no project — so the bar must offer exactly All, Flotilla
    /// and General, and General must be a real group rather than the absence
    /// of one.
    func testGroupChipsNarrowTheGridAndSurviveAPresentationSwitch() {
        let app = launchedApp()
        showGrid(app)

        let all = element(app, "Sessions.Group-All")
        XCTAssertTrue(fastWait(all, timeout: 5), "the group bar should be present in Sessions")
        XCTAssertTrue(element(app, "Sessions.Group-Flotilla").exists)
        XCTAssertTrue(element(app, "Sessions.Group-General").exists)

        // Add all inside General fills the grid from that group only.
        element(app, "Sessions.Group-General").click()
        let addAll = element(app, "Grid.AddAllButton")
        XCTAssertTrue(fastWait(addAll, timeout: 3))
        addAll.click()

        let general = element(app, "GridTile-Code review assistant-Status")
        XCTAssertTrue(fastWait(general, timeout: 5), "a General session should be in the grid")
        XCTAssertFalse(
            element(app, "GridTile-Fix login bug-Status").exists,
            "a project session must not render while the General group is lit"
        )

        // Presentation changes *how* the fleet is drawn, never *what* is in
        // it: the group has to survive a round trip through Board.
        element(app, "Toolbar.ShowBoard").click()
        XCTAssertTrue(fastWait(element(app, "KanbanBoard"), timeout: 8))
        showGrid(app)

        XCTAssertTrue(fastWait(element(app, "GridTile-Code review assistant-Status"), timeout: 5))
        XCTAssertFalse(
            element(app, "GridTile-Fix login bug-Status").exists,
            "the group should still be General after switching presentation and back"
        )
    }

    /// Renaming from the bar is the first UI path into
    /// `AppStore.renameSession` — the method shipped with no caller at all,
    /// so a session could only be renamed by its agent reporting a new title.
    func testRenamingFromTheSessionBarReachesTheStore() {
        let app = launchedApp()

        let sessionRow = element(app, "Sidebar.SessionRow-Fix login bug")
        if fastWait(sessionRow, timeout: 5) {
            sessionRow.doubleClick()
        }

        let title = element(app, "SessionBar-Fix login bug-Title")
        XCTAssertTrue(fastWait(title, timeout: 5), "the focused session should carry a session bar")
        title.click()

        let field = element(app, "SessionBar-Fix login bug-TitleField")
        XCTAssertTrue(fastWait(field, timeout: 3), "clicking the title should open an inline field")
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Fix logout bug\r")

        // The sidebar row is rendered from the store, so its new title is
        // proof the edit was persisted rather than just redrawn in the bar.
        XCTAssertTrue(
            fastWait(element(app, "Sidebar.SessionRow-Fix logout bug"), timeout: 5),
            "the renamed session should appear under its new title in the navigator"
        )
    }
}
