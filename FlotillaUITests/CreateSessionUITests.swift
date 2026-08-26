import XCTest

/// Covers the modal New Session window (`CommandBarDesign`, opened via ⌘N /
/// the sidebar button / the command palette). The home dashboard's inline
/// composer (`LaunchpadDesign`) is covered separately in
/// `HomeComposerUITests`.
@MainActor
final class CreateSessionUITests: XCTestCase {
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        return app
    }

    /// Always re-queries. Holding onto a `firstMatch` across an interaction
    /// goes stale here: `ModelPickerView` finishes its CLI model fetch
    /// asynchronously and rebuilds the control row underneath a cached handle.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @discardableResult
    private func tap(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 3) -> Bool {
        guard fastWait(element(app, identifier), timeout: timeout) else { return false }
        element(app, identifier).click()
        return true
    }

    private func openLauncher(_ app: XCUIApplication) {
        XCTAssertTrue(fastWait(element(app, "NewSessionButton"), timeout: 8))
        element(app, "NewSessionButton").click()
        XCTAssertTrue(fastWait(element(app, "CreateSession.GoalField"), timeout: 3))
    }

    private func typeGoal(_ app: XCUIApplication, _ text: String) {
        XCTAssertTrue(fastWait(element(app, "CreateSession.GoalField"), timeout: 3))
        element(app, "CreateSession.GoalField").click()
        element(app, "CreateSession.GoalField").typeText(text)
    }

    /// Drives the launcher purely through accessibility identifiers, not
    /// visible labels — a segmented-picker label match (`app.radioButtons["New
    /// Worktree"]`) only worked because the old form happened to use
    /// `.segmented` pickers everywhere; `CommandBarDesign` uses chips and an
    /// inline result list instead.
    func testCreateGeneralAndWorktreeSessions() {
        let app = launchedApp()

        // MARK: General session

        openLauncher(app)
        typeGoal(app, "Flaky CI")
        XCTAssertTrue(tap(app, "CreateSession.Agent.codexCLI"))
        XCTAssertTrue(tap(app, "CreateSession.CreateButton"))
        XCTAssertTrue(element(app, "CreateSession.CreateButton").waitForNonExistence(timeout: 5))

        XCTAssertTrue(fastWait(element(app, "SessionRow-Flaky CI"), timeout: 3))
        XCTAssertTrue(fastWait(element(app, "SessionRow-Flaky CI-Agent"), timeout: 3))
        XCTAssertEqual(element(app, "SessionRow-Flaky CI-Agent").value as? String, "Codex CLI")

        // MARK: Project session in a new worktree

        openLauncher(app)

        // The project picker replaces the old "Project Folder" segment: it
        // reveals the known-project list, with the panel as a fallback.
        XCTAssertTrue(tap(app, "CreateSession.ProjectPicker"))
        XCTAssertTrue(tap(app, "CreateSession.ChooseFolderButton"))

        typeGoal(app, "Dark mode")

        // Isolation only appears once a folder is chosen — a general session
        // has nothing to isolate.
        XCTAssertTrue(tap(app, "CreateSession.Checkout.Worktree"))
        XCTAssertTrue(tap(app, "CreateSession.CreateButton"))
        XCTAssertTrue(element(app, "CreateSession.CreateButton").waitForNonExistence(timeout: 5))

        XCTAssertTrue(fastWait(element(app, "SessionRow-Dark mode"), timeout: 3))
        XCTAssertTrue(fastWait(element(app, "SessionRow-Dark mode-Branch"), timeout: 3))
        let branch = element(app, "SessionRow-Dark mode-Branch").value as? String ?? ""
        XCTAssertTrue(branch.contains("dark-mode"), branch)
    }

    /// The empty-goal case is only reachable through the modal: it allows a
    /// bare interactive agent because opening the window was already a
    /// deliberate action, unlike the always-visible home composer.
    func testModalLauncherAllowsAnEmptyGoal() {
        let app = launchedApp()
        openLauncher(app)

        XCTAssertTrue(fastWait(element(app, "CreateSession.CreateButton"), timeout: 3))
        XCTAssertTrue(element(app, "CreateSession.CreateButton").isEnabled)
    }
}
