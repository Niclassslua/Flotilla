import XCTest

@MainActor
final class OnboardingUITests: XCTestCase {
    func testSkipIsRememberedAfterRelaunch() {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launchEnvironment["UI_TESTING_SHOW_ONBOARDING"] = "1"
        app.launchEnvironment["UI_TESTING_SETTINGS_SUITE"] = "FlotillaUITests-\(UUID().uuidString)"
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        let skip = app.buttons["Onboarding.SkipButton"]
        XCTAssertTrue(skip.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Onboarding.BetaBadge"].exists)
        skip.click()
        XCTAssertTrue(skip.waitForNonExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["SidebarList"].waitForExistence(timeout: 15))
        XCTAssertFalse(skip.exists)
        app.terminate()
    }
}
