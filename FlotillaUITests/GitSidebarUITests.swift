import XCTest

@MainActor
final class GitSidebarUITests: XCTestCase {
    private func element(_ app: XCUIApplication, _ id: AXID) -> XCUIElement {
        element(app, id.rawValue)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testSidebarOpensAndSwitchesAcrossAllThreeViews() {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()

        let sessions = app.radioButtons["Sessions"].firstMatch
        if sessions.waitForExistence(timeout: 2) {
            sessions.click()
        } else {
            let allSessions = element(app, .sidebarAllSessions)
            XCTAssertTrue(allSessions.waitForExistence(timeout: 3))
            allSessions.click()
        }

        let session = element(app, AXID.sessionRow("Refactor sidebar"))
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.click()

        let toggle = element(app, .sessionBarGitSidebarToggle)
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        toggle.click()

        XCTAssertTrue(element(app, .gitSidebar).waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, .gitSidebarChangesMode).waitForExistence(timeout: 3))

        element(app, AXID.gitSidebarTab("Branches")).click()
        XCTAssertTrue(element(app, .gitSidebarBranchesNew).waitForExistence(timeout: 3))

        element(app, AXID.gitSidebarTab("Log")).click()
        XCTAssertTrue(element(app, .gitSidebarLogBranch).waitForExistence(timeout: 3))
        XCTAssertTrue(element(app, .gitSidebarLogList).waitForExistence(timeout: 5))
    }
}
