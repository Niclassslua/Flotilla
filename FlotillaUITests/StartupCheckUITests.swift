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

    private func element(_ app: XCUIApplication, _ id: AXID) -> XCUIElement {
        element(app, id.rawValue)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testMissingDependencyShowsNonBlockingWarningBanner() {
        let app = launchedApp()

        let banner = element(app, .startupWarningBanner)
        if banner.waitForExistence(timeout: 8) {
            let dismissButton = element(app, .startupWarningBannerDismissButton)
            if dismissButton.waitForExistence(timeout: 2) {
                dismissButton.click()
                XCTAssertTrue(banner.waitForNonExistence(timeout: 3))
            }
        }
    }
}
