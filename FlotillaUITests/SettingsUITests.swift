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

    private func element(_ app: XCUIApplication, _ id: AXID) -> XCUIElement {
        element(app, id.rawValue)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testWorktreeBaseDirectorySettingUpdate() {
        let app = launchedApp()

        // The app menu, by position: its title is the product name, which
        // differs per build configuration ("Flotilla Dev" under Debug).
        let appMenuBarItem = app.menuBarItems.element(boundBy: 1)
        XCTAssertTrue(fastWait(appMenuBarItem, timeout: 8))
        let settingsMenuItem = app.menuItems["Settings…"]
        XCTAssertTrue(fastWait(settingsMenuItem, timeout: 3))
        settingsMenuItem.click()

        let generalRow = element(app, AXID.settingsSidebarTab("general"))
        if fastWait(generalRow, timeout: 3) {
            generalRow.click()
        }

        let worktreeField = app.descendants(matching: .textField)[AXID.settingsWorktreeBaseDirectory.rawValue].firstMatch
        XCTAssertTrue(fastWait(worktreeField, timeout: 3))
        worktreeField.click()
        app.typeKey("a", modifierFlags: [.command])
        app.typeText("/tmp/flotilla-custom-worktrees")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    }

    func testKeyboardShortcutReferenceOpensFromCommandPalette() {
        let app = launchedApp()

        app.typeKey("k", modifierFlags: .command)
        let search = element(app, "CommandPalette.Search")
        XCTAssertTrue(fastWait(search, timeout: 5))
        search.typeText("keyboard shortcuts")

        let shortcutCommand = element(app, "CommandPalette.Row-Keyboard shortcuts")
        XCTAssertTrue(fastWait(shortcutCommand, timeout: 3))
        shortcutCommand.click()

        XCTAssertTrue(fastWait(element(app, "KeyboardShortcuts"), timeout: 5))
    }
}
