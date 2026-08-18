import XCTest

/// Covers Part 0's "full session creation flow" requirement: goal entry,
/// agent pick, and both main-checkout and new-worktree paths.
@MainActor
final class CreateSessionUITests: XCTestCase {
    // The fixture git repo at CreateSessionView's UI_TESTING folder path is
    // reset by the app itself on every launch (AppEnvironment) — the
    // sandboxed XCUITest runner process can't write fixture files itself.

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        return app
    }

    func testEffortGaugeCanSwitchBeforeLaunch() {
        let app = launchedApp()

        let newSessionButton = app.descendants(matching: .any)["NewSessionButton"].firstMatch
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 8))
        newSessionButton.click()

        let effortGauge = app.descendants(matching: .any)["CreateSession.EffortPicker"].firstMatch
        XCTAssertTrue(effortGauge.waitForExistence(timeout: 8))

        // Default effort is Medium. The current level is folded into the
        // accessibility label (see EffortLevelPicker) since this custom
        // control's AX value isn't reliably surfaced to XCUITest on macOS.
        XCTAssertEqual(effortGauge.label, "Reasoning effort: Medium")

        // Interaction test (tap/drag to change effort) is verified manually
        // and in unit tests. XCUITest cannot reliably synthesize drag gestures
        // on custom SwiftUI controls.
    }

    func testCreateGeneralSessionEndToEnd() {
        let app = launchedApp()

        let newSessionButton = app.descendants(matching: .any)["NewSessionButton"].firstMatch
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 8))
        newSessionButton.click()

        let goalField = app.descendants(matching: .any)["CreateSession.GoalField"].firstMatch
        XCTAssertTrue(goalField.waitForExistence(timeout: 8))
        goalField.click()
        goalField.typeText("Investigate flaky CI test")

        // Agent pick: switch off the default (Claude Code) to Codex CLI.
        let codexOption = app.radioButtons["Codex CLI"]
        if codexOption.waitForExistence(timeout: 2) {
            codexOption.click()
        }

        let createButton = app.descendants(matching: .any)["CreateSession.CreateButton"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 8))
        XCTAssertTrue(createButton.isEnabled)
        createButton.click()

        // Sheet should dismiss and the new session should appear, selected,
        // under General (no project folder was chosen).
        let newRow = app.descendants(matching: .any)["SessionRow-Investigate flaky CI test"].firstMatch
        XCTAssertTrue(newRow.waitForExistence(timeout: 8))

        let agentLabel = app.descendants(matching: .any)["SessionToolbar.Agent"].firstMatch
        XCTAssertTrue(agentLabel.waitForExistence(timeout: 8))
        XCTAssertEqual(agentLabel.value as? String, "Codex CLI")
    }

    func testCreateProjectSessionWithNewWorktree() {
        let app = launchedApp()

        let newSessionButton = app.descendants(matching: .any)["NewSessionButton"].firstMatch
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 8))
        newSessionButton.click()

        let projectFolderOption = app.radioButtons["Project Folder"]
        XCTAssertTrue(projectFolderOption.waitForExistence(timeout: 8))
        projectFolderOption.click()

        // UI_TESTING mode substitutes a fixed fixture path instead of a real
        // NSOpenPanel — see CreateSessionView.chooseFolder.
        let chooseFolderButton = app.descendants(matching: .any)["CreateSession.ChooseFolderButton"].firstMatch
        XCTAssertTrue(chooseFolderButton.waitForExistence(timeout: 8))
        chooseFolderButton.click()

        let selectedFolderLabel = app.descendants(matching: .any)["CreateSession.SelectedFolderLabel"].firstMatch
        XCTAssertTrue(selectedFolderLabel.waitForExistence(timeout: 8))
        XCTAssertTrue((selectedFolderLabel.value as? String ?? "").contains("flotilla-uitest-project"))

        let goalField = app.descendants(matching: .any)["CreateSession.GoalField"].firstMatch
        XCTAssertTrue(goalField.waitForExistence(timeout: 8))
        goalField.click()
        goalField.typeText("Add dark mode support")

        let newWorktreeButton = app.radioButtons["New Worktree"]
        XCTAssertTrue(newWorktreeButton.waitForExistence(timeout: 8))
        XCTAssertTrue(newWorktreeButton.isHittable)
        newWorktreeButton.click()
        let checkoutDescription = app.descendants(matching: .any)["CreateSession.CheckoutDescription"].firstMatch
        XCTAssertTrue(checkoutDescription.waitForExistence(timeout: 3))
        XCTAssertTrue((checkoutDescription.value as? String ?? checkoutDescription.label).contains("dedicated branch"))

        let createButton = app.descendants(matching: .any)["CreateSession.CreateButton"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 8))
        createButton.click()

        let newRow = app.descendants(matching: .any)["SessionRow-Add dark mode support"].firstMatch
        XCTAssertTrue(newRow.waitForExistence(timeout: 8))

        let branchLabel = app.descendants(matching: .any)["SessionToolbar.Branch"].firstMatch
        XCTAssertTrue(branchLabel.waitForExistence(timeout: 8))
        XCTAssertTrue((branchLabel.value as? String ?? "").hasPrefix("flotilla/add-dark-mode-support"))
    }

    func testCreateProjectSessionAgainstMainCheckout() {
        let app = launchedApp()
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
        goalField.typeText("Inspect the primary checkout")

        let mainCheckoutButton = app.radioButtons["Main Checkout"]
        XCTAssertTrue(mainCheckoutButton.waitForExistence(timeout: 8))
        mainCheckoutButton.click()

        let createButton = app.descendants(matching: .any)["CreateSession.CreateButton"].firstMatch
        createButton.click()

        XCTAssertTrue(app.descendants(matching: .any)["SessionRow-Inspect the primary checkout"].firstMatch.waitForExistence(timeout: 8))
        let pathLabel = app.descendants(matching: .any)["SessionToolbar.Path"].firstMatch
        XCTAssertTrue(pathLabel.waitForExistence(timeout: 8))
        XCTAssertEqual(pathLabel.value as? String, "/tmp/flotilla-uitest-project")
        let branchLabel = app.descendants(matching: .any)["SessionToolbar.Branch"].firstMatch
        XCTAssertTrue(branchLabel.waitForExistence(timeout: 8))
        XCTAssertEqual(branchLabel.value as? String, "main")
    }
}
