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

        // No toolbar button for Rules — reach it the way a user would, via
        // the Workspace menu's shortcut, which jumps to the project's Rules tab.
        app.typeKey("i", modifierFlags: [.command, .shift])

        let claudeFile = app.descendants(matching: .any)["Knowledge.Item-CLAUDE.md"].firstMatch
        XCTAssertTrue(fastWait(claudeFile, timeout: 3))
        claudeFile.click()

        let editButton = app.descendants(matching: .any)["Knowledge.Detail.Edit"].firstMatch
        XCTAssertTrue(fastWait(editButton, timeout: 3))
        editButton.click()

        let editor = app.descendants(matching: .any)["Knowledge.Detail.Editor"].firstMatch
        XCTAssertTrue(fastWait(editor, timeout: 3))
        editor.click()

        let marker = "\nUI test \(UUID().uuidString.prefix(6))"
        editor.typeKey(XCUIKeyboardKey.end.rawValue, modifierFlags: [.command])
        editor.typeText(marker)

        let saveButton = app.descendants(matching: .any)["Knowledge.Detail.Save"].firstMatch
        XCTAssertTrue(fastWait(saveButton, timeout: 3))
        saveButton.click()

        let confirmation = app.descendants(matching: .any)["Knowledge.Detail.SaveStatus"].firstMatch
        XCTAssertTrue(fastWait(confirmation, timeout: 3))
        XCTAssertEqual(confirmation.label, "Saved")

        // Real end-to-end check: read the file straight off disk.
        let claudeMdPath = "/tmp/flotilla-uitest-project/CLAUDE.md"
        let onDiskContent = try String(contentsOfFile: claudeMdPath, encoding: .utf8)
        XCTAssertTrue(onDiskContent.contains("UI test"))
    }
}
