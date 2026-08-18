import XCTest

/// Covers Part 0's Rules & Skills panel requirement: editing a rule file
/// in-app persists to disk. Reads the saved file directly from disk after
/// clicking Save — the XCUITest runner can read anywhere (just not write
/// outside its own sandbox container), so this is a genuine end-to-end
/// check, not just an accessibility-tree assertion.
@MainActor
final class RulesPanelUITests: XCTestCase {
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        return app
    }

    private func createFixtureProjectSession(_ app: XCUIApplication, goal: String) {
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
        goalField.typeText(goal)

        // This test verifies the exact fixture file path below, so opt into
        // the main checkout instead of depending on the user's worktree
        // default from Settings.
        let mainCheckout = app.radioButtons["Main Checkout"]
        XCTAssertTrue(mainCheckout.waitForExistence(timeout: 8))
        mainCheckout.click()

        let createButton = app.descendants(matching: .any)["CreateSession.CreateButton"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 8))
        createButton.click()

        let row = app.descendants(matching: .any)["SessionRow-\(goal)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
    }

    func testEditingRuleFilePersistsToDisk() throws {
        let app = launchedApp()
        createFixtureProjectSession(app, goal: "Rules panel test session")

        let paletteButton = app.descendants(matching: .any)["CommandPaletteButton"].firstMatch
        XCTAssertTrue(paletteButton.waitForExistence(timeout: 8))
        paletteButton.click()

        let search = app.descendants(matching: .any)["CommandPalette.Search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.click()
        search.typeText("View instructions")

        let rulesCommand = app.descendants(matching: .any)["CommandPalette.Row-View instructions"].firstMatch
        XCTAssertTrue(rulesCommand.waitForExistence(timeout: 8))
        rulesCommand.click()

        let claudeFile = app.descendants(matching: .any)["RulesPanel.File-CLAUDE.md"].firstMatch
        XCTAssertTrue(claudeFile.waitForExistence(timeout: 8))
        claudeFile.click()

        let editor = app.descendants(matching: .any)["RulesPanel.Editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        editor.click()

        let marker = "\nAppended by UI test \(UUID().uuidString.prefix(8))"
        // Move to the end of the existing content before appending.
        editor.typeKey(XCUIKeyboardKey.end.rawValue, modifierFlags: [.command])
        editor.typeText(marker)
        XCTAssertTrue((editor.value as? String ?? "").contains("Appended by UI test"))

        let saveButton = app.descendants(matching: .any)["RulesPanel.SaveButton"].firstMatch
        XCTAssertTrue(saveButton.waitForExistence(timeout: 8))
        saveButton.click()

        let confirmation = app.descendants(matching: .any)["RulesPanel.SaveConfirmation"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 8))
        XCTAssertEqual(confirmation.label, "Saved")

        // Real end-to-end check: read the file straight off disk.
        let claudeMdPath = "/tmp/flotilla-uitest-project/CLAUDE.md"
        let onDiskContent = try String(contentsOfFile: claudeMdPath, encoding: .utf8)
        XCTAssertTrue(onDiskContent.contains("Appended by UI test"))
    }
}
