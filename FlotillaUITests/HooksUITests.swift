import XCTest

@MainActor
final class HooksUITests: XCTestCase {
    func testSimulatedPermissionPromptDisplaysActionableStatus() {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launchEnvironment["UI_TESTING_SIMULATE_WAITING_SESSION"] = "General chat"
        app.launch()

        // All Sessions is a navigator row now, not a toolbar segment — the
        // scope picker went with the facet split.
        let allSessions = app.descendants(matching: .any)["Sidebar.AllSessions"].firstMatch
        XCTAssertTrue(allSessions.waitForExistence(timeout: 4))
        allSessions.click()

        let sessionRow = app.descendants(matching: .any)["SessionRow-General chat"].firstMatch
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 8))

        // The waiting reason has to reach the row as a word, not as a colour:
        // that is the whole point of a status the user is meant to act on.
        // Matched across the row's descendants rather than through a button —
        // sidebar rows are `List` selection targets and carry no button of
        // their own.
        let statusWord = sessionRow.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Needs Permission"))
            .firstMatch
        XCTAssertTrue(statusWord.waitForExistence(timeout: 3), "row should name the waiting reason")
    }
}
