import XCTest

/// Covers Part 0's hooks/notifications requirement: a simulated
/// waiting-for-input state fires a notification. Since the real system
/// Notification Center is out-of-process and not inspectable via
/// XCUITest, `HookCoordinator.lastNotifiedSessionTitle` is surfaced
/// through an always-mounted, invisible `Text` (`LastNotifiedSession`) —
/// this test drives the real HooksKit pipeline by scheduling agent output
/// from the test-only mock process, then reads that observable result.
@MainActor
final class HooksUITests: XCTestCase {
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launchEnvironment["UI_TESTING_SIMULATE_WAITING_SESSION"] = "Fix login bug"
        app.launch()
        return app
    }

    func testSimulatedWaitingForInputFiresNotification() {
        let app = launchedApp()

        // Clicking the row mounts the session's terminal, which is what
        // gives the screen reader something to read: the simulated prompt is
        // replayed into the emulator and classified from there.
        let row = app.descendants(matching: .any)["SessionRow-Fix login bug"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.click()

        let banner = app.descendants(matching: .any)["LastNotifiedSession"].firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 8))

        let predicate = NSPredicate { _, _ in
            (banner.value as? String) == "Fix login bug"
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 8), .completed)

        // The session's own status indicator must also reflect the change.
        let statusDot = app.descendants(matching: .any)["SessionToolbar.Status"].firstMatch
        XCTAssertTrue(statusDot.waitForExistence(timeout: 8))
        XCTAssertEqual(statusDot.label, "Waiting for Input")
    }
}
