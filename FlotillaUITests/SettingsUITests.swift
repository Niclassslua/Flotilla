import XCTest

@MainActor
final class SettingsUITests: XCTestCase {
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        return app
    }

    func testWorktreeBaseDirectorySettingUpdate() {
        let app = launchedApp()

        let appMenuBarItem = app.menuBarItems["Flotilla"]
        XCTAssertTrue(fastWait(appMenuBarItem, timeout: 8))
        let settingsMenuItem = app.menuItems["Settings…"]
        XCTAssertTrue(fastWait(settingsMenuItem, timeout: 3))
        settingsMenuItem.click()

        let generalRow = app.descendants(matching: .any)["settings.sidebar.general"].firstMatch
        if fastWait(generalRow, timeout: 3) {
            generalRow.click()
        }

        let worktreeField = app.descendants(matching: .textField)["Settings.WorktreeBaseDirectory"].firstMatch
        XCTAssertTrue(fastWait(worktreeField, timeout: 3))
        worktreeField.click()
        app.typeKey("a", modifierFlags: [.command])
        app.typeText("/tmp/flotilla-custom-worktrees")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    }
}
