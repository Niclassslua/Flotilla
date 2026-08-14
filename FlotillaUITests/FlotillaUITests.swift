import XCTest

/// `UI_TESTING=1` makes `AppEnvironment` swap in an in-memory repository
/// seeded with fixture sessions (see `AppEnvironment.seedFixtures`) so
/// these tests never touch the real database, filesystem, or git.
@MainActor
final class FlotillaUITests: XCTestCase {
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        return app
    }

    func testAppLaunchesWithSplitViewShell() {
        let app = launchedApp()

        // NavigationSplitView owns its own internal accessibility identifier
        // for the SplitGroup element (state-restoration related), so it's
        // matched structurally rather than by a custom identifier.
        XCTAssertTrue(app.splitGroups.firstMatch.waitForExistence(timeout: 5))

        // Query by identifier across any element type: List renders as an
        // outline (not .table) on macOS, and ContentUnavailableView is a
        // composite whose identifier lands on its child text, so pin to
        // .any rather than a specific role.
        XCTAssertTrue(app.descendants(matching: .any)["SidebarList"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["DetailPlaceholder"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Choose a session"].waitForExistence(timeout: 5))
    }

    func testSelectingSessionUpdatesToolbarAndDetail() {
        let app = launchedApp()

        // Rows render as several accessibility elements sharing one
        // identifier (status dot + title + subtitle), so pin to the first.
        let firstRow = app.descendants(matching: .any)["SessionRow-Fix login bug"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        firstRow.click()

        // A parent-level accessibilityIdentifier on the toolbar's HStack
        // was found to override children's individual identifiers on
        // macOS AX, so toolbar presence is checked via a child identifier
        // (Agent) rather than a container-level one.
        let toolbar = app.descendants(matching: .any)["SessionToolbar.Agent"].firstMatch
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5))

        let branchLabel = app.descendants(matching: .any)["SessionToolbar.Branch"].firstMatch
        XCTAssertTrue(branchLabel.waitForExistence(timeout: 5))
        XCTAssertTrue((branchLabel.value as? String ?? "").contains("fix-login-bug"))

        // Switching to a second session must update the toolbar in place.
        let secondRow = app.descendants(matching: .any)["SessionRow-Refactor sidebar"].firstMatch
        XCTAssertTrue(secondRow.waitForExistence(timeout: 5))
        secondRow.click()

        let updatedBranchLabel = app.descendants(matching: .any)["SessionToolbar.Branch"].firstMatch
        XCTAssertTrue(updatedBranchLabel.waitForExistence(timeout: 5))
        XCTAssertTrue((updatedBranchLabel.value as? String ?? "").contains("main"))
    }

    func testGlobalHomeCommandPaletteAndProjectNavigation() {
        let app = launchedApp()

        let homeButton = app.descendants(matching: .any)["Global.Home"].firstMatch
        XCTAssertTrue(homeButton.waitForExistence(timeout: 5))
        homeButton.click()
        XCTAssertTrue(app.staticTexts["What should an agent build?"].waitForExistence(timeout: 5))

        let paletteButton = app.descendants(matching: .any)["CommandPaletteButton"].firstMatch
        XCTAssertTrue(paletteButton.waitForExistence(timeout: 5))
        paletteButton.click()

        let search = app.descendants(matching: .any)["CommandPalette.Search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("Go to Projects")

        let openProjects = app.descendants(matching: .any)["CommandPalette.Row-Go to Projects"].firstMatch
        XCTAssertTrue(openProjects.waitForExistence(timeout: 5))
        openProjects.click()

        let project = app.descendants(matching: .any)["ProjectRow-Flotilla"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.click()
        XCTAssertTrue(app.staticTexts["Start something new"].waitForExistence(timeout: 5))
    }
}
