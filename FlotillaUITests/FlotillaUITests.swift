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

        // 1. Session selection updates toolbar and detail
        let firstRow = app.descendants(matching: .any)["SessionRow-Fix login bug"].firstMatch
        XCTAssertTrue(fastWait(firstRow, timeout: 8))
        firstRow.click()

        let toolbar = app.descendants(matching: .any)["SessionToolbar.Agent"].firstMatch
        XCTAssertTrue(fastWait(toolbar, timeout: 3))

        let branchLabel = app.descendants(matching: .any)["SessionToolbar.Branch"].firstMatch
        XCTAssertTrue(fastWait(branchLabel, timeout: 3))
        let branch = "\(branchLabel.label) \(branchLabel.value as? String ?? "")"
        XCTAssertTrue(branch.contains("fix-login-bug"))

        let secondRow = app.descendants(matching: .any)["SessionRow-Refactor sidebar"].firstMatch
        XCTAssertTrue(fastWait(secondRow, timeout: 3))
        secondRow.click()

        let updatedBranchLabel = app.descendants(matching: .any)["SessionToolbar.Branch"].firstMatch
        XCTAssertTrue(fastWait(updatedBranchLabel, timeout: 3))
        let updatedBranch = "\(updatedBranchLabel.label) \(updatedBranchLabel.value as? String ?? "")"
        XCTAssertTrue(updatedBranch.contains("main"))

        // 2. Global Overview and Project drilldown navigation
        let homeButton = app.descendants(matching: .any)["Sidebar.Overview"].firstMatch
        XCTAssertTrue(fastWait(homeButton, timeout: 3))
        homeButton.click()
        XCTAssertTrue(fastWait(app.descendants(matching: .any)["HomeDashboard"].firstMatch, timeout: 3))

        let projectCard = app.descendants(matching: .any)["ProjectRow-Flotilla"].firstMatch
        XCTAssertTrue(fastWait(projectCard, timeout: 3))
        projectCard.click()

        let backButton = app.descendants(matching: .any)["ProjectDetail.BackButton"].firstMatch
        XCTAssertTrue(fastWait(backButton, timeout: 3))
    }
}
