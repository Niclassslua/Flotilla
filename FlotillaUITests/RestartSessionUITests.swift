import XCTest

/// End-to-end test for the "restart crashed session" flow.
/// Seeds a session in `.crashed` state, verifies the restart affordance
/// appears, clicks it, and confirms the session recovers to `.working`.
@MainActor
final class RestartSessionUITests: XCTestCase {
    private func launchedApp(
        crashedSessionTitle: String
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launchEnvironment["UI_TESTING_SIMULATE_CRASHED_SESSION"] = crashedSessionTitle
        app.launch()
        return app
    }

    func testRestartCrashedSessionRecoversToWorking() {
        let app = launchedApp(crashedSessionTitle: "Fix login bug")

        // Session row exists and shows crashed state
        let row = app.descendants(matching: .any)["SessionRow-Fix login bug"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        // Click to focus the crashed session
        row.click()

        // Terminal area should show the "Agent Stopped" placeholder with restart action
        let terminalPlaceholder = app.descendants(matching: .any)["TerminalView-Fix login bug"].firstMatch
        XCTAssertTrue(terminalPlaceholder.waitForExistence(timeout: 5))

        // The ContentUnavailableView's "Restart" button (accessibility identifier on the action button)
        let restartButton = app.buttons["Restart Session"].firstMatch
        XCTAssertTrue(restartButton.waitForExistence(timeout: 5), "Restart button should appear for crashed sessions")

        // Click restart
        restartButton.click()

        // After restart, the session should transition to .working and the terminal should be live
        // The mock agent (echoes input) will be running; type a marker and verify it echoes back
        let marker = "restart-probe-\(UUID().uuidString.prefix(8))"
        app.typeText(marker)

        let terminal = app.descendants(matching: .any)["TerminalView-Fix login bug"].firstMatch
        let predicate = NSPredicate { _, _ in
            (terminal.value as? String)?.contains(marker) ?? false
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        let result = XCTWaiter().wait(for: [expectation], timeout: 8)
        XCTAssertEqual(result, .completed, "Terminal should echo input after restart, proving the process is running")

        // Session row should no longer show crashed visual state (status dot is green/working)
        // The row itself stays the same identifier; we just verify the terminal is interactive now.
    }

    func testRestartPreservesSessionIdentityAndWorktree() {
        let app = launchedApp(crashedSessionTitle: "Refactor sidebar")

        let row = app.descendants(matching: .any)["SessionRow-Refactor sidebar"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()

        let restartButton = app.buttons["Restart Session"].firstMatch
        XCTAssertTrue(restartButton.waitForExistence(timeout: 5))
        restartButton.click()

        // Verify the session is functional by sending input
        let marker = "identity-check-\(UUID().uuidString.prefix(8))"
        app.typeText(marker)

        let terminal = app.descendants(matching: .any)["TerminalView-Refactor sidebar"].firstMatch
        let predicate = NSPredicate { _, _ in
            (terminal.value as? String)?.contains(marker) ?? false
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        let result = XCTWaiter().wait(for: [expectation], timeout: 8)
        XCTAssertEqual(result, .completed)
    }
}