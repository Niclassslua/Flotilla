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

    private func element(_ app: XCUIApplication, _ id: AXID) -> XCUIElement {
        element(app, id.rawValue)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testDeleteSessionBothPaths() {
        let app = launchedApp()

        // 1. Delete fixture session without worktree (main checkout)
        let refactorRow = element(app, AXID.sessionRow("Refactor sidebar"))
        XCTAssertTrue(fastWait(refactorRow, timeout: 8))
        refactorRow.rightClick()

        let deleteRefactorItem = element(app, AXID.sessionRowDeleteMenuItem("Refactor sidebar"))
        XCTAssertTrue(fastWait(deleteRefactorItem, timeout: 3))
        deleteRefactorItem.click()

        let deleteOnlyButton = element(app, .deleteSessionDeleteOnly)
        XCTAssertTrue(fastWait(deleteOnlyButton, timeout: 3))
        deleteOnlyButton.click()
        XCTAssertTrue(refactorRow.waitForNonExistence(timeout: 3))

        // 2. Delete fixture session with worktree cleanup
        let fixLoginRow = element(app, AXID.sessionRow("Fix login bug"))
        XCTAssertTrue(fastWait(fixLoginRow, timeout: 3))

        let worktreePath = "/tmp/flotilla-fixture-project-worktrees/fix-login-bug"
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath), "worktree should exist before deletion")

        fixLoginRow.rightClick()
        let deleteFixLoginItem = element(app, AXID.sessionRowDeleteMenuItem("Fix login bug"))
        XCTAssertTrue(deleteFixLoginItem.waitForExistence(timeout: 3))
        deleteFixLoginItem.click()

        let deleteWithWorktreeButton = element(app, .deleteSessionDeleteWithWorktree)
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
