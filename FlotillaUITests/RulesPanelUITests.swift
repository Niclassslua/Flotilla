import XCTest

@MainActor
final class RulesPanelUITests: XCTestCase {
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        return app
    }

    func testEditingRuleFilePersistsToDisk() throws {
        let app = launchedApp()
        let sessionRow = app.descendants(matching: .any)["SessionRow-Refactor sidebar"].firstMatch
        XCTAssertTrue(fastWait(sessionRow, timeout: 8))
        sessionRow.click()

        let inspectorToggle = app.descendants(matching: .any)["Toolbar.InspectorToggle"].firstMatch
        XCTAssertTrue(fastWait(inspectorToggle, timeout: 3))
        inspectorToggle.click()

        let instructionsTab = app.radioButtons["Instructions"].firstMatch
        XCTAssertTrue(fastWait(instructionsTab, timeout: 3))
        instructionsTab.click()

        let claudeFile = app.descendants(matching: .any)["RulesPanel.File-CLAUDE.md"].firstMatch
        XCTAssertTrue(fastWait(claudeFile, timeout: 3))
        claudeFile.click()

        let editor = app.descendants(matching: .any)["RulesPanel.Editor"].firstMatch
        XCTAssertTrue(fastWait(editor, timeout: 3))
        editor.click()

        let marker = "\nUI test \(UUID().uuidString.prefix(6))"
        editor.typeKey(XCUIKeyboardKey.end.rawValue, modifierFlags: [.command])
        editor.typeText(marker)

        let saveButton = app.descendants(matching: .any)["RulesPanel.SaveButton"].firstMatch
        XCTAssertTrue(fastWait(saveButton, timeout: 3))
        saveButton.click()

        let confirmation = app.descendants(matching: .any)["RulesPanel.SaveConfirmation"].firstMatch
        XCTAssertTrue(fastWait(confirmation, timeout: 3))
        XCTAssertEqual(confirmation.label, "Saved")

        // Real end-to-end check: read the file straight off disk.
        let claudeMdPath = "/tmp/flotilla-uitest-project/CLAUDE.md"
        let onDiskContent = try String(contentsOfFile: claudeMdPath, encoding: .utf8)
        XCTAssertTrue(onDiskContent.contains("UI test"))
    }
}
