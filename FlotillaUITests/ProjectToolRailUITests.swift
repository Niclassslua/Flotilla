import XCTest

/// End-to-end contracts for issue #7's persistent project tool rail.
@MainActor
final class ProjectToolRailUITests: XCTestCase {
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

    private func rail(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        element(app, "ProjectToolRail.\(title)")
    }

    func testRailDisabledOnHomeEnabledOnProjectAndOpensTools() {
        let app = launchedApp()

        let railRoot = element(app, .projectToolRail)
        XCTAssertTrue(railRoot.waitForExistence(timeout: 8), "tool rail must be present at launch")

        let git = rail(app, "Git")
        let files = rail(app, "Files")
        let issues = rail(app, "Issues")
        let skills = rail(app, "Skills")
        let rules = rail(app, "Rules")
        for tool in [git, files, issues, skills, rules] {
            XCTAssertTrue(tool.waitForExistence(timeout: 3))
            XCTAssertFalse(tool.isEnabled, "Home has no project context — tools must be disabled")
        }

        // Project header → overview; rail enables, nothing selected.
        let project = element(app, AXID.sidebarProjectRow("Flotilla"))
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.click()
        XCTAssertTrue(git.isEnabled)
        XCTAssertFalse(git.isSelected)

        git.click()
        XCTAssertTrue(git.isSelected)
        XCTAssertTrue(
            element(app, "ProjectGit.SubTab-Commits").waitForExistence(timeout: 5)
            || element(app, "ProjectGit.SubTab-Changes").waitForExistence(timeout: 1),
            "rail Git must open the project Git surface"
        )
        // Session list stays global — General sessions remain visible.
        XCTAssertTrue(element(app, AXID.sessionRow("General chat")).exists)

        // Clicking the active tool again leaves it open (still selected).
        git.click()
        XCTAssertTrue(git.isSelected)

        files.click()
        XCTAssertTrue(files.isSelected)
        XCTAssertFalse(git.isSelected)
        XCTAssertTrue(element(app, AXID.fileBrowserRow("README.md")).waitForExistence(timeout: 5))

        // Session click returns to the terminal; rail keeps project context,
        // but no tool is highlighted.
        let session = element(app, AXID.sessionRow("Refactor sidebar"))
        XCTAssertTrue(session.waitForExistence(timeout: 3))
        session.click()
        XCTAssertTrue(element(app, .sessionBarGitSidebarToggle).waitForExistence(timeout: 5))
        XCTAssertTrue(git.isEnabled)
        XCTAssertFalse(files.isSelected)
        XCTAssertFalse(git.isSelected)

        // Folder button removed from the session bar.
        XCTAssertFalse(
            element(app, .toolbarOpenProjectFiles).exists,
            "session folder button must be gone — Files lives on the rail"
        )

        // General session disables the rail again.
        let general = element(app, AXID.sessionRow("General chat"))
        XCTAssertTrue(general.waitForExistence(timeout: 3))
        general.click()
        XCTAssertFalse(git.isEnabled, "General sessions must disable project tools")
    }

    func testOneProjectGridFilterEnablesRailWithoutFocusChangingContext() {
        let app = launchedApp()

        let grid = element(app, .toolbarShowGrid)
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        grid.click()

        let flotillaGroup = element(app, AXID.sessionsGroup("Flotilla"))
        XCTAssertTrue(flotillaGroup.waitForExistence(timeout: 5))
        flotillaGroup.click()

        let git = rail(app, "Git")
        XCTAssertTrue(git.waitForExistence(timeout: 3))
        XCTAssertTrue(git.isEnabled, "a one-project Grid filter enables the rail")

        // Focusing a tile must not be required for tools to work, and must
        // not clear the collection's project context.
        git.click()
        XCTAssertTrue(git.isSelected)
        XCTAssertTrue(
            element(app, "ProjectGit.SubTab-Commits").waitForExistence(timeout: 5)
            || element(app, "ProjectGit.SubTab-Changes").waitForExistence(timeout: 1)
        )
    }
}
