import XCTest

@MainActor
final class FlotillaUITests: XCTestCase {
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        return app
    }

    /// Fast-accessibility-existence polling.
    ///
    /// XCTest's `waitForExistence` carries a ~1.17s fixed overhead due to its
    /// 1-second NSPredicate polling interval, regardless of whether the element
    /// already exists or how short the timeout is. This helper polls `element.exists`
    /// at ~50ms intervals, achieving the same logical result with dramatically
    /// lower wall-clock cost.
    func fastWait(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists { return true }
            usleep(50_000)  // 50 ms
        }
        return element.exists
    }

    func testNavigationAndSessionSelection() {
        let app = launchedApp()

        // 1. Session selection updates the window title and detail
        let firstRow = app.descendants(matching: .any)["SessionRow-Fix login bug"].firstMatch
        XCTAssertTrue(fastWait(firstRow, timeout: 8))
        firstRow.click()

        // Session identity lives in the window title bar, set via
        // DetailColumn's navigationTitle/navigationSubtitle. Both halves are
        // asserted: the subtitle carries the branch and agent, which appear
        // nowhere else while a session is focused.
        let window = app.windows.firstMatch
        XCTAssertTrue(fastWait(window, timeout: 3))
        XCTAssertTrue(window.title.hasPrefix("Fix login bug"), "unexpected title: \(window.title)")
        XCTAssertTrue(window.title.contains("flotilla/fix-login-bug"), "branch missing from title: \(window.title)")

        let secondRow = app.descendants(matching: .any)["SessionRow-Refactor sidebar"].firstMatch
        XCTAssertTrue(fastWait(secondRow, timeout: 3))
        secondRow.click()
        XCTAssertTrue(fastWait(window, timeout: 3))
        XCTAssertTrue(window.title.hasPrefix("Refactor sidebar"), "unexpected title: \(window.title)")

        // 2. Home is reachable from the navigator in every scope.
        let homeButton = app.descendants(matching: .any)["Sidebar.Overview"].firstMatch
        XCTAssertTrue(fastWait(homeButton, timeout: 3))
        homeButton.click()
        XCTAssertTrue(fastWait(app.descendants(matching: .any)["HomeDashboard"].firstMatch, timeout: 3))

        // 3. So is a project's workspace — directly, with no mode switch and
        // without scrolling to the foot of Home to find a tile. Projects are
        // selectable navigator rows rather than inert section headers.
        let projectRow = app.descendants(matching: .any)["Sidebar.ProjectRow-Flotilla"].firstMatch
        XCTAssertTrue(fastWait(projectRow, timeout: 3), "projects should be selectable in the navigator")
        projectRow.click()

        let backButton = app.descendants(matching: .any)["ProjectDetail.BackButton"].firstMatch
        XCTAssertTrue(fastWait(backButton, timeout: 3))

        // 4. Back returns to Home, the place we came from.
        let back = app.descendants(matching: .any)["Toolbar.Back"].firstMatch
        XCTAssertTrue(fastWait(back, timeout: 3))
        back.click()
        XCTAssertTrue(fastWait(app.descendants(matching: .any)["HomeDashboard"].firstMatch, timeout: 3))
    }
}
