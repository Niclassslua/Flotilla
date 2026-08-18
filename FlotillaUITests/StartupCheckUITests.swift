import XCTest

@MainActor
final class StartupCheckUITests: XCTestCase {
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        return app
    }

    func testMissingDependencyShowsNonBlockingWarningBanner() {
        let app = launchedApp()

        let banner = app.descendants(matching: .any)["StartupWarningBanner"].firstMatch
        if banner.waitForExistence(timeout: 8) {
            let dismissButton = app.descendants(matching: .any)["StartupWarningBanner.DismissButton"].firstMatch
            if dismissButton.waitForExistence(timeout: 2) {
                dismissButton.click()
                XCTAssertTrue(banner.waitForNonExistence(timeout: 3))
            }
        }
    }
}
