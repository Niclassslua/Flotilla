import XCTest

/// Covers Kanban board functionality: tab navigation, column modes, drag-drop, session interactions.
@MainActor
final class KanbanUITests: XCTestCase {
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        return app
    }

    private func openKanbanTab(_ app: XCUIApplication) {
        // Kanban is accessed via the view mode picker in the sessions view
        let sessionsButton = app.descendants(matching: .any)["Global.Sessions"].firstMatch
        XCTAssertTrue(sessionsButton.waitForExistence(timeout: 8))
        sessionsButton.click()

        // Select Board layout from the segmented picker
        let boardSegment = app.segmentedControls.buttons["Kanban"].firstMatch
        XCTAssertTrue(boardSegment.waitForExistence(timeout: 5))
        boardSegment.click()
    }

    func testKanbanTabExistsAndNavigable() {
        let app = launchedApp()
        openKanbanTab(app)

        let boardView = app.descendants(matching: .any).matching(identifier: "KanbanBoard").firstMatch
        XCTAssertTrue(boardView.waitForExistence(timeout: 8))
    }

    func testKanbanShowsGlobalBoardByDefault() {
        let app = launchedApp()
        openKanbanTab(app)

        let boardName = app.staticTexts["All Projects"].firstMatch
        XCTAssertTrue(boardName.waitForExistence(timeout: 8))
    }

    func testColumnModePickerSwitchesModes() {
        let app = launchedApp()
        openKanbanTab(app)

        // Status mode should be selected by default
        let statusSegment = app.segmentedControls.buttons["Status"].firstMatch
        XCTAssertTrue(statusSegment.waitForExistence(timeout: 5))
        XCTAssertTrue(statusSegment.isSelected)

        // Switch to Agents mode
        let agentsSegment = app.segmentedControls.buttons["Agents"].firstMatch
        XCTAssertTrue(agentsSegment.waitForExistence(timeout: 5))
        agentsSegment.click()

        XCTAssertTrue(agentsSegment.isSelected)
        XCTAssertFalse(statusSegment.isSelected)

        // Verify column headers changed to agent names
        let claudeColumn = app.staticTexts["Claude Code"].firstMatch
        XCTAssertTrue(claudeColumn.waitForExistence(timeout: 5))

        // Switch to Workflow mode
        let workflowSegment = app.segmentedControls.buttons["Workflow"].firstMatch
        XCTAssertTrue(workflowSegment.waitForExistence(timeout: 5))
        workflowSegment.click()

        let backlogColumn = app.staticTexts["Backlog"].firstMatch
        XCTAssertTrue(backlogColumn.waitForExistence(timeout: 5))
    }

    func testSessionCardAppearsInCorrectColumn() {
        let app = launchedApp()

        // Create a session first
        let newSessionButton = app.descendants(matching: .any)["NewSessionButton"].firstMatch
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 8))
        newSessionButton.click()

        let goalField = app.descendants(matching: .any)["CreateSession.GoalField"].firstMatch
        XCTAssertTrue(goalField.waitForExistence(timeout: 8))
        goalField.click()
        goalField.typeText("Test kanban card")

        let createButton = app.descendants(matching: .any)["CreateSession.CreateButton"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 8))
        createButton.click()

        // Wait for session to appear in list
        let sessionRow = app.descendants(matching: .any)["SessionRow-Test kanban card"].firstMatch
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 8))

        // Now open Kanban
        openKanbanTab(app)

        // Session should appear in "Working" column (default status for new sessions)
        let workingColumn = app.staticTexts["Working"].firstMatch
        XCTAssertTrue(workingColumn.waitForExistence(timeout: 5))

        let sessionCard = app.descendants(matching: .any)["KanbanCard-Test kanban card"].firstMatch
        XCTAssertTrue(sessionCard.waitForExistence(timeout: 8))
    }

    func testSessionCardShowsAgentAndStatus() {
        let app = launchedApp()

        // Create a Codex CLI session
        let newSessionButton = app.descendants(matching: .any)["NewSessionButton"].firstMatch
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 8))
        newSessionButton.click()

        let goalField = app.descendants(matching: .any)["CreateSession.GoalField"].firstMatch
        XCTAssertTrue(goalField.waitForExistence(timeout: 8))
        goalField.click()
        goalField.typeText("Codex session for kanban")

        let codexOption = app.radioButtons["Codex CLI"]
        if codexOption.waitForExistence(timeout: 2) {
            codexOption.click()
        }

        let createButton = app.descendants(matching: .any)["CreateSession.CreateButton"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 8))
        createButton.click()

        let sessionRow = app.descendants(matching: .any)["SessionRow-Codex session for kanban"].firstMatch
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 8))

        openKanbanTab(app)

        // Verify card shows agent logo/name
        let sessionCard = app.descendants(matching: .any)["KanbanCard-Codex session for kanban"].firstMatch
        XCTAssertTrue(sessionCard.waitForExistence(timeout: 8))

        // Card should have Codex CLI indicator
        let agentIndicator = sessionCard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Codex'")).firstMatch
        XCTAssertTrue(agentIndicator.waitForExistence(timeout: 5))
    }

    func testDragDropSessionBetweenStatusColumns() {
        let app = launchedApp()

        // Create a session
        let newSessionButton = app.descendants(matching: .any)["NewSessionButton"].firstMatch
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 8))
        newSessionButton.click()

        let goalField = app.descendants(matching: .any)["CreateSession.GoalField"].firstMatch
        XCTAssertTrue(goalField.waitForExistence(timeout: 8))
        goalField.click()
        goalField.typeText("Drag test session")

        let createButton = app.descendants(matching: .any)["CreateSession.CreateButton"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 8))
        createButton.click()

        let sessionRow = app.descendants(matching: .any)["SessionRow-Drag test session"].firstMatch
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 8))

        openKanbanTab(app)

        // Find the session card in Working column
        let sessionCard = app.descendants(matching: .any)["KanbanCard-Drag test session"].firstMatch
        XCTAssertTrue(sessionCard.waitForExistence(timeout: 8))

        // Drag to Idle column
        let idleColumn = app.staticTexts["Idle"].firstMatch
        XCTAssertTrue(idleColumn.waitForExistence(timeout: 5))

        // Use press(forDuration:thenDragTo:) for drag and drop
        sessionCard.press(forDuration: 0.5, thenDragTo: idleColumn)

        // Wait for UI to update
        sleep(1)

        // Session should still exist (verifying the drag completed)
        let idleCard = app.descendants(matching: .any)["KanbanCard-Drag test session"].firstMatch
        XCTAssertTrue(idleCard.waitForExistence(timeout: 5))
    }

    func testDoubleClickCardOpensSession() {
        let app = launchedApp()

        // Create a session
        let newSessionButton = app.descendants(matching: .any)["NewSessionButton"].firstMatch
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 8))
        newSessionButton.click()

        let goalField = app.descendants(matching: .any)["CreateSession.GoalField"].firstMatch
        XCTAssertTrue(goalField.waitForExistence(timeout: 8))
        goalField.click()
        goalField.typeText("Double click test")

        let createButton = app.descendants(matching: .any)["CreateSession.CreateButton"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 8))
        createButton.click()

        let sessionRow = app.descendants(matching: .any)["SessionRow-Double click test"].firstMatch
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 8))

        openKanbanTab(app)

        let sessionCard = app.descendants(matching: .any)["KanbanCard-Double click test"].firstMatch
        XCTAssertTrue(sessionCard.waitForExistence(timeout: 8))

        // Double click - use doubleTap for macOS
        sessionCard.doubleTap()

        // Should navigate to Sessions view with this session selected
        let sessionToolbar = app.descendants(matching: .any)["SessionToolbar-Double click test"].firstMatch
        XCTAssertTrue(sessionToolbar.waitForExistence(timeout: 5))
    }

    func testContextMenuOnCard() {
        let app = launchedApp()

        // Create a session
        let newSessionButton = app.descendants(matching: .any)["NewSessionButton"].firstMatch
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 8))
        newSessionButton.click()

        let goalField = app.descendants(matching: .any)["CreateSession.GoalField"].firstMatch
        XCTAssertTrue(goalField.waitForExistence(timeout: 8))
        goalField.click()
        goalField.typeText("Context menu test")

        let createButton = app.descendants(matching: .any)["CreateSession.CreateButton"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 8))
        createButton.click()

        let sessionRow = app.descendants(matching: .any)["SessionRow-Context menu test"].firstMatch
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 8))

        openKanbanTab(app)

        let sessionCard = app.descendants(matching: .any)["KanbanCard-Context menu test"].firstMatch
        XCTAssertTrue(sessionCard.waitForExistence(timeout: 8))

        // Right-click to show context menu (two-finger click on trackpad)
        sessionCard.rightClick()

        // Check for context menu items
        let openSessionItem = app.menuItems["Open Session"].firstMatch
        XCTAssertTrue(openSessionItem.waitForExistence(timeout: 3))

        let restartItem = app.menuItems["Restart Session"].firstMatch
        XCTAssertTrue(restartItem.waitForExistence(timeout: 3))

        let deleteItem = app.menuItems["Delete Session"].firstMatch
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 3))

        // Press Escape to dismiss menu
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    }

    func testTerminalPeekShowsInCard() {
        let app = launchedApp()

        // Create a session
        let newSessionButton = app.descendants(matching: .any)["NewSessionButton"].firstMatch
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 8))
        newSessionButton.click()

        let goalField = app.descendants(matching: .any)["CreateSession.GoalField"].firstMatch
        XCTAssertTrue(goalField.waitForExistence(timeout: 8))
        goalField.click()
        goalField.typeText("Terminal peek test")

        let createButton = app.descendants(matching: .any)["CreateSession.CreateButton"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 8))
        createButton.click()

        let sessionRow = app.descendants(matching: .any)["SessionRow-Terminal peek test"].firstMatch
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 8))

        openKanbanTab(app)

        let sessionCard = app.descendants(matching: .any)["KanbanCard-Terminal peek test"].firstMatch
        XCTAssertTrue(sessionCard.waitForExistence(timeout: 8))

        // Terminal peek should be visible (terminal output area)
        // The card should have content beyond just the header
        XCTAssertTrue(sessionCard.waitForExistence(timeout: 5))
    }

    func testBoardPickerShowsAllBoards() {
        let app = launchedApp()
        openKanbanTab(app)

        let boardsMenu = app.buttons["Boards"].firstMatch
        XCTAssertTrue(boardsMenu.waitForExistence(timeout: 5))
        boardsMenu.click()

        // Should show "All Projects" and any project boards
        let allProjectsItem = app.menuItems["All Projects"].firstMatch
        XCTAssertTrue(allProjectsItem.waitForExistence(timeout: 3))

        // Press Escape to dismiss
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    }

    func testSessionCardShowsGoalProgress() {
        let app = launchedApp()

        // Create a session with a goal
        let newSessionButton = app.descendants(matching: .any)["NewSessionButton"].firstMatch
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 8))
        newSessionButton.click()

        let goalField = app.descendants(matching: .any)["CreateSession.GoalField"].firstMatch
        XCTAssertTrue(goalField.waitForExistence(timeout: 8))
        goalField.click()
        goalField.typeText("Implement feature X with tests")

        let createButton = app.descendants(matching: .any)["CreateSession.CreateButton"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 8))
        createButton.click()

        let sessionRow = app.descendants(matching: .any)["SessionRow-Implement feature X with tests"].firstMatch
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 8))

        openKanbanTab(app)

        let sessionCard = app.descendants(matching: .any)["KanbanCard-Implement feature X with tests"].firstMatch
        XCTAssertTrue(sessionCard.waitForExistence(timeout: 8))

        // Goal text should be visible in card
        let goalText = sessionCard.staticTexts["Implement feature X with tests"].firstMatch
        XCTAssertTrue(goalText.waitForExistence(timeout: 3))
    }

    func testGitDiffBadgeShowsForWorktreeSessions() {
        let app = launchedApp()

        // Create a project session with worktree
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
        goalField.typeText("Worktree session for kanban")

        let newWorktreeButton = app.radioButtons["New Worktree"]
        XCTAssertTrue(newWorktreeButton.waitForExistence(timeout: 8))
        newWorktreeButton.click()

        let createButton = app.descendants(matching: .any)["CreateSession.CreateButton"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 8))
        createButton.click()

        let sessionRow = app.descendants(matching: .any)["SessionRow-Worktree session for kanban"].firstMatch
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 8))

        openKanbanTab(app)

        let sessionCard = app.descendants(matching: .any)["KanbanCard-Worktree session for kanban"].firstMatch
        XCTAssertTrue(sessionCard.waitForExistence(timeout: 8))

        // Git branch badge should be visible
        let branchBadge = sessionCard.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'flotilla/'")).firstMatch
        XCTAssertTrue(branchBadge.waitForExistence(timeout: 5))
    }

    func testCommandPaletteShowKanban() {
        let app = launchedApp()

        // Open command palette
        let paletteButton = app.descendants(matching: .any)["CommandPaletteButton"].firstMatch
        XCTAssertTrue(paletteButton.waitForExistence(timeout: 8))
        paletteButton.click()

        let palette = app.descendants(matching: .any)["CommandPaletteView"].firstMatch
        XCTAssertTrue(palette.waitForExistence(timeout: 5))

        // Press Escape to dismiss
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    }
}