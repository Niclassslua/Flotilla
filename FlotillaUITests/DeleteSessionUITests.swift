import XCTest

/// Covers Part 0's requirement: deleting a session offers to clean up the
/// worktree and branch. Reads the worktree path directly off disk after
/// deletion (the runner can read anywhere, just not write outside its own
/// sandbox container) for a genuine end-to-end confirmation, not just an
/// accessibility-tree check.
@MainActor
final class DeleteSessionUITests: XCTestCase {
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        return app
    }

    func testDeletingSessionWithWorktreeCleansUpDirectoryAndBranch() {
        let app = launchedApp()

        // Create a project session with a new worktree.
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
        goalField.typeText("Delete cleanup test")

        let newWorktreeButton = app.radioButtons["New Worktree"]
        XCTAssertTrue(newWorktreeButton.waitForExistence(timeout: 8))
        XCTAssertTrue(newWorktreeButton.isHittable)
        newWorktreeButton.click()
        let checkoutDescription = app.descendants(matching: .any)["CreateSession.CheckoutDescription"].firstMatch
        XCTAssertTrue((checkoutDescription.value as? String ?? checkoutDescription.label).contains("dedicated branch"))

        let createButton = app.descendants(matching: .any)["CreateSession.CreateButton"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 8))
        createButton.click()

        let row = app.descendants(matching: .any)["SessionRow-Delete cleanup test"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))

        let pathLabel = app.descendants(matching: .any)["SessionToolbar.Path"].firstMatch
        XCTAssertTrue(pathLabel.waitForExistence(timeout: 8))
        let worktreePath = pathLabel.value as? String ?? ""
        XCTAssertTrue(worktreePath.contains("delete-cleanup-test"), "unexpected worktree path: \(worktreePath)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath), "worktree should exist before deletion")

        // Right-click the row to bring up the delete context menu item.
        row.rightClick()
        let deleteMenuItem = app.descendants(matching: .any)["SessionRow-Delete cleanup test-DeleteMenuItem"].firstMatch
        XCTAssertTrue(deleteMenuItem.waitForExistence(timeout: 8))
        deleteMenuItem.click()

        let deleteWithWorktreeButton = app.descendants(matching: .any)["DeleteSessionDialog.DeleteWithWorktree"].firstMatch
        XCTAssertTrue(deleteWithWorktreeButton.waitForExistence(timeout: 8))
        deleteWithWorktreeButton.click()

        XCTAssertTrue(row.waitForNonExistence(timeout: 8))

        // The real end-to-end check: the worktree directory is gone from disk.
        let predicate = NSPredicate { _, _ in
            !FileManager.default.fileExists(atPath: worktreePath)
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 8), .completed, "worktree directory should be removed from disk")
    }

    /// The row's always-present trash button is the fast path to the same
    /// confirmation sheet the context menu opens — one click instead of
    /// right-click-then-menu-item.
    func testRowDeleteButtonOpensConfirmationAndRemovesSession() {
        let app = launchedApp()

        // The app launches on the Home destination; the sidebar (and its
        // SessionRow elements) only renders under the Sessions tab.
        let sessionsTab = app.descendants(matching: .any)["Global.Sessions"].firstMatch
        XCTAssertTrue(sessionsTab.waitForExistence(timeout: 8))
        sessionsTab.click()

        let row = app.descendants(matching: .any)["SessionRow-Fix login bug"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))

        let deleteButton = app.descendants(matching: .any)["SessionRow-Fix login bug-DeleteButton"].firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 8))
        deleteButton.click()

        let deleteSessionOnlyButton = app.descendants(matching: .any)["DeleteSessionDialog.DeleteSessionOnly"].firstMatch
        XCTAssertTrue(deleteSessionOnlyButton.waitForExistence(timeout: 8))
        deleteSessionOnlyButton.click()

        XCTAssertTrue(row.waitForNonExistence(timeout: 8))
    }
}
