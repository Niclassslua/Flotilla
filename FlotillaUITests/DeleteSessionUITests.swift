import XCTest

@MainActor
final class DeleteSessionUITests: XCTestCase {
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        return app
    }

    func testDeleteSessionBothPaths() {
        let app = launchedApp()

        // 1. Delete fixture session without worktree (main checkout)
        let refactorRow = app.descendants(matching: .any)["SessionRow-Refactor sidebar"].firstMatch
        XCTAssertTrue(fastWait(refactorRow, timeout: 8))
        refactorRow.rightClick()

        let deleteRefactorItem = app.descendants(matching: .any)["SessionRow-Refactor sidebar-DeleteMenuItem"].firstMatch
        XCTAssertTrue(fastWait(deleteRefactorItem, timeout: 3))
        deleteRefactorItem.click()

        let deleteOnlyButton = app.descendants(matching: .any)["DeleteSessionDialog.DeleteSessionOnly"].firstMatch
        XCTAssertTrue(fastWait(deleteOnlyButton, timeout: 3))
        deleteOnlyButton.click()
        XCTAssertTrue(refactorRow.waitForNonExistence(timeout: 3))

        // 2. Delete fixture session with worktree cleanup
        let fixLoginRow = app.descendants(matching: .any)["SessionRow-Fix login bug"].firstMatch
        XCTAssertTrue(fastWait(fixLoginRow, timeout: 3))

        let worktreePath = "/tmp/flotilla-fixture-project-worktrees/fix-login-bug"
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath), "worktree should exist before deletion")

        fixLoginRow.rightClick()
        let deleteFixLoginItem = app.descendants(matching: .any)["SessionRow-Fix login bug-DeleteMenuItem"].firstMatch
        XCTAssertTrue(deleteFixLoginItem.waitForExistence(timeout: 3))
        deleteFixLoginItem.click()

        let deleteWithWorktreeButton = app.descendants(matching: .any)["DeleteSessionDialog.DeleteWithWorktree"].firstMatch
        XCTAssertTrue(deleteWithWorktreeButton.waitForExistence(timeout: 3))
        deleteWithWorktreeButton.click()

        XCTAssertTrue(fixLoginRow.waitForNonExistence(timeout: 3))

        // Real end-to-end check: the worktree directory is gone from disk.
        let predicate = NSPredicate { _, _ in
            !FileManager.default.fileExists(atPath: worktreePath)
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 5), .completed, "worktree directory should be removed from disk")
    }
}
