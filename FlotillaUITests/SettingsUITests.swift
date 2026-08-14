import XCTest

/// Covers Part 0's Settings requirement: settings persist AND are actually
/// consumed (no dead config). Rather than just checking the field holds
/// its value, this drives a real worktree creation afterward and confirms
/// the resulting worktree path is rooted under the custom directory —
/// proof the setting reaches `SessionProcessManager`/`AppStore`, not just
/// `UserDefaults`.
@MainActor
final class SettingsUITests: XCTestCase {
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        return app
    }

    func testWorktreeBaseDirectorySettingIsConsumedByNewWorktreeCreation() {
        let app = launchedApp()

        // Wait for the main window before opening Settings — sending Cmd+,
        // before it exists can result in only the Settings window ever
        // appearing.
        XCTAssertTrue(app.descendants(matching: .any)["SidebarList"].firstMatch.waitForExistence(timeout: 15))

        // Menu bar rather than the Cmd+, shortcut — more robust to focus
        // timing than a raw keyboard shortcut right after launch.
        let appMenuBarItem = app.menuBarItems["Flotilla"]
        XCTAssertTrue(appMenuBarItem.waitForExistence(timeout: 8))
        appMenuBarItem.click()
        let settingsMenuItem = app.menuItems["Settings…"]
        XCTAssertTrue(settingsMenuItem.waitForExistence(timeout: 8))
        settingsMenuItem.click()

        let settingsView = app.descendants(matching: .any)["SettingsView"].firstMatch
        XCTAssertTrue(settingsView.waitForExistence(timeout: 8))

        let worktreeField = app.descendants(matching: .any)["Settings.WorktreeBaseDirectory"].firstMatch
        XCTAssertTrue(worktreeField.waitForExistence(timeout: 8))
        worktreeField.click()
        // Clear any existing value, then type the custom directory.
        app.typeKey("a", modifierFlags: [.command])
        app.typeText("/tmp/flotilla-custom-worktrees")
        app.typeKey(.tab, modifierFlags: []) // commit the field

        // Settings is a non-modal auxiliary window — no need to close it
        // before interacting with the main window underneath.
        let newSessionButton = app.descendants(matching: .any)["NewSessionButton"].firstMatch
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 8))
        newSessionButton.click()

        let projectFolderOption = app.radioButtons["Project Folder"]
        XCTAssertTrue(projectFolderOption.waitForExistence(timeout: 8))
        projectFolderOption.click()

        let chooseFolderButton = app.descendants(matching: .any)["CreateSession.ChooseFolderButton"].firstMatch
        XCTAssertTrue(chooseFolderButton.waitForExistence(timeout: 8))
        chooseFolderButton.click()

        let goalField = app.descendants(matching: .any)["CreateSession.GoalField"].firstMatch
        XCTAssertTrue(goalField.waitForExistence(timeout: 8))
        goalField.click()
        goalField.typeText("Settings consumption test")

        let newWorktreeButton = app.radioButtons["New Worktree"]
        XCTAssertTrue(newWorktreeButton.waitForExistence(timeout: 8))
        XCTAssertTrue(newWorktreeButton.isHittable)
        newWorktreeButton.click()
        let checkoutDescription = app.descendants(matching: .any)["CreateSession.CheckoutDescription"].firstMatch
        XCTAssertTrue((checkoutDescription.value as? String ?? checkoutDescription.label).contains("dedicated branch"))

        let createButton = app.descendants(matching: .any)["CreateSession.CreateButton"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 8))
        createButton.click()

        let row = app.descendants(matching: .any)["SessionRow-Settings consumption test"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))

        let pathLabel = app.descendants(matching: .any)["SessionToolbar.Path"].firstMatch
        XCTAssertTrue(pathLabel.waitForExistence(timeout: 8))
        let path = pathLabel.value as? String ?? ""
        XCTAssertTrue(path.contains("flotilla-custom-worktrees"), "worktree path '\(path)' should be rooted under the custom Settings directory")
    }
}
