import XCTest

/// Covers Part 0's requirement: startup check surfaces a non-blocking
/// warning when a dependency is simulated as missing.
/// `UI_TESTING_SIMULATE_MISSING_TOOLS` forces specific tools to appear
/// missing regardless of what's actually installed on the machine running
/// the test (see `StartupCheckViewModel`).
@MainActor
final class StartupCheckUITests: XCTestCase {
    func testMissingDependencyShowsNonBlockingWarningBanner() {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launchEnvironment["UI_TESTING_SIMULATE_MISSING_TOOLS"] = "tmux,gh"
        app.launch()

        let banner = app.descendants(matching: .any)["StartupWarningBanner"].firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 8))
        let warningText = "\(banner.label) \(banner.value as? String ?? "")"
        XCTAssertTrue(warningText.contains("tmux"))
        XCTAssertTrue(warningText.contains("gh"))

        // Non-blocking: the rest of the app is still fully usable with the
        // banner showing.
        let newSessionButton = app.descendants(matching: .any)["NewSessionButton"].firstMatch
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 8))
        XCTAssertTrue(newSessionButton.isEnabled)

        let dismissButton = app.descendants(matching: .any)["StartupWarningBanner.DismissButton"].firstMatch
        XCTAssertTrue(dismissButton.waitForExistence(timeout: 8))
        dismissButton.click()

        XCTAssertTrue(banner.waitForNonExistence(timeout: 8))
    }

    func testNoMissingDependenciesShowsNoBanner() {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launchEnvironment["UI_TESTING_SIMULATE_MISSING_TOOLS"] = "none"
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["SidebarList"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["StartupWarningBanner"].firstMatch.exists)
    }
}
