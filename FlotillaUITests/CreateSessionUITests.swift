import XCTest

@MainActor
final class CreateSessionUITests: XCTestCase {
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        return app
    }

    func testCreateGeneralAndWorktreeSessions() {
        let app = launchedApp()

        // 1. General session creation
        let newSessionButton = app.descendants(matching: .any)["NewSessionButton"].firstMatch
        XCTAssertTrue(fastWait(newSessionButton, timeout: 8))
        newSessionButton.click()

        let goalField = app.descendants(matching: .any)["CreateSession.GoalField"].firstMatch
        XCTAssertTrue(fastWait(goalField, timeout: 3))
        goalField.click()
        goalField.typeText("Flaky CI")

        let codexOption = app.radioButtons["Codex CLI"]
        if codexOption.exists {
            codexOption.click()
        }

        let createButton = app.descendants(matching: .any)["CreateSession.CreateButton"].firstMatch
        XCTAssertTrue(fastWait(createButton, timeout: 3))
        createButton.click()
        XCTAssertTrue(createButton.waitForNonExistence(timeout: 3))

        let newRow = app.descendants(matching: .any)["SessionRow-Flaky CI"].firstMatch
        XCTAssertTrue(fastWait(newRow, timeout: 3))
        let agentLabel = app.descendants(matching: .any)["SessionToolbar.Agent"].firstMatch
        XCTAssertTrue(fastWait(agentLabel, timeout: 3))
        XCTAssertEqual(agentLabel.value as? String, "Codex CLI")

        // 2. Project session with New Worktree
        XCTAssertTrue(fastWait(newSessionButton, timeout: 3))
        newSessionButton.click()

        let projectFolderOption = app.radioButtons["Project Folder"]
        XCTAssertTrue(fastWait(projectFolderOption, timeout: 3))
        projectFolderOption.click()

        let chooseFolderButton = app.descendants(matching: .any)["CreateSession.ChooseFolderButton"].firstMatch
        XCTAssertTrue(fastWait(chooseFolderButton, timeout: 3))
        chooseFolderButton.click()

        XCTAssertTrue(fastWait(goalField, timeout: 3))
        goalField.click()
        goalField.typeText("Dark mode")

        let newWorktreeOption = app.radioButtons["New Worktree"]
        XCTAssertTrue(fastWait(newWorktreeOption, timeout: 3))
        newWorktreeOption.click()

        XCTAssertTrue(fastWait(createButton, timeout: 3))
        createButton.click()
        XCTAssertTrue(createButton.waitForNonExistence(timeout: 3))

        let worktreeRow = app.descendants(matching: .any)["SessionRow-Dark mode"].firstMatch
        XCTAssertTrue(fastWait(worktreeRow, timeout: 3))
        let branchLabel = app.descendants(matching: .any)["SessionToolbar.Branch"].firstMatch
        XCTAssertTrue(fastWait(branchLabel, timeout: 3))
        let branch = "\(branchLabel.label) \(branchLabel.value as? String ?? "")"
        XCTAssertTrue(branch.contains("dark-mode"))
    }
}
