import XCTest

@MainActor
final class GitSidebarUITests: XCTestCase {
    func testSidebarOpensAndSwitchesAcrossAllThreeViews() {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()

        let sessions = app.radioButtons["Sessions"].firstMatch
        if sessions.waitForExistence(timeout: 2) {
            sessions.click()
        } else {
            let allSessions = app.descendants(matching: .any)["Sidebar.AllSessions"].firstMatch
            XCTAssertTrue(allSessions.waitForExistence(timeout: 3))
            allSessions.click()
        }

        let session = app.descendants(matching: .any)["SessionRow-Refactor sidebar"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.click()

        let toggle = app.descendants(matching: .any)["SessionBar.GitSidebarToggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        toggle.click()

        XCTAssertTrue(app.descendants(matching: .any)["GitSidebar"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["GitSidebar.Changes.Mode"].firstMatch.waitForExistence(timeout: 3))

        app.descendants(matching: .any)["GitSidebar.Tab.Branches"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["GitSidebar.Branches.New"].firstMatch.waitForExistence(timeout: 3))

        app.descendants(matching: .any)["GitSidebar.Tab.Log"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["GitSidebar.Log.Branch"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["GitSidebar.Log.List"].firstMatch.waitForExistence(timeout: 5))
    }
}
