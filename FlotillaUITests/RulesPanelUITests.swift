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

    private func element(_ app: XCUIApplication, _ id: AXID) -> XCUIElement {
        element(app, id.rawValue)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testEditingRuleFilePersistsToDisk() throws {
        let app = launchedApp()
        let sessionRow = element(app, AXID.sessionRow("Refactor sidebar"))
        XCTAssertTrue(fastWait(sessionRow, timeout: 8))
        sessionRow.click()

        // No toolbar button for Rules — reach it the way a user would, via
        // the Workspace menu's shortcut, which jumps to the project's Rules tab.
        app.typeKey("i", modifierFlags: [.command, .shift])

        let claudeFile = element(app, AXID.knowledgeItem("CLAUDE.md"))
        XCTAssertTrue(fastWait(claudeFile, timeout: 3))
        claudeFile.click()

        let editButton = element(app, .knowledgeEditButton)
        XCTAssertTrue(fastWait(editButton, timeout: 3))
        editButton.click()

        let editor = element(app, .knowledgeDetailEditor)
        XCTAssertTrue(fastWait(editor, timeout: 3))
        editor.click()

        let marker = "\nUI test \(UUID().uuidString.prefix(6))"
        editor.typeKey(XCUIKeyboardKey.end.rawValue, modifierFlags: [.command])
        editor.typeText(marker)

        let saveButton = element(app, .knowledgeSaveButton)
        XCTAssertTrue(fastWait(saveButton, timeout: 3))
        saveButton.click()

        let confirmation = element(app, .knowledgeSaveStatus)
        XCTAssertTrue(fastWait(confirmation, timeout: 3))
        XCTAssertEqual(confirmation.label, "Saved")

        // Real end-to-end check: read the file straight off disk.
        let claudeMdPath = "/tmp/flotilla-uitest-project/CLAUDE.md"
        let onDiskContent = try String(contentsOfFile: claudeMdPath, encoding: .utf8)
        XCTAssertTrue(onDiskContent.contains("UI test"))
    }
}
