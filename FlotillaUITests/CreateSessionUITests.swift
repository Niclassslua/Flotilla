import XCTest

/// Covers the modal New Session window (`TilesDesign`, opened via ⌘N /
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

    private func element(_ app: XCUIApplication, _ id: AXID) -> XCUIElement {
        element(app, id.rawValue)
    }

    @discardableResult
    private func tap(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 3) -> Bool {
        guard fastWait(element(app, identifier), timeout: timeout) else { return false }
        element(app, identifier).click()
        return true
    }

    @discardableResult
    private func tap(_ app: XCUIApplication, _ id: AXID, timeout: TimeInterval = 3) -> Bool {
        tap(app, id.rawValue, timeout: timeout)
    }

    private func openLauncher(_ app: XCUIApplication) {
        XCTAssertTrue(fastWait(element(app, .newSessionButton), timeout: 8))
        element(app, .newSessionButton).click()
        XCTAssertTrue(fastWait(element(app, .createSessionGoalField), timeout: 3))
    }

    private func typeGoal(_ app: XCUIApplication, _ text: String) {
        XCTAssertTrue(fastWait(element(app, .createSessionGoalField), timeout: 3))
        element(app, .createSessionGoalField).click()
        element(app, .createSessionGoalField).typeText(text)
    }

    /// Drives the launcher purely through accessibility identifiers, not
    /// visible labels, so the interaction contract remains stable even if the
    /// compact Tile controls' copy changes.
    func testCreateGeneralAndWorktreeSessions() {
        let app = launchedApp()

        // MARK: General session

        openLauncher(app)
        typeGoal(app, "Flaky CI")
        XCTAssertTrue(tap(app, AXID.createSessionAgentOption("codexCLI")))
        XCTAssertTrue(tap(app, .createSessionCreateButton))
        XCTAssertTrue(element(app, .createSessionCreateButton).waitForNonExistence(timeout: 5))

        XCTAssertTrue(fastWait(element(app, AXID.sessionRow("Flaky CI")), timeout: 3))
        // The agent is asserted on the window subtitle rather than the row.
        // Navigator rows carry status and churn only now — the agent is the
        // provider tile beside the title, and the branch would repeat what the
        // subtitle already says once the session is open.
        assertWindowIdentity(app, contains: "Codex CLI")

        // MARK: Project session in a new worktree

        openLauncher(app)

        // The project picker replaces the old "Project Folder" segment: it
        // reveals the known-project list, with the panel as a fallback.
        XCTAssertTrue(tap(app, .createSessionProjectPicker))
        XCTAssertTrue(tap(app, .createSessionChooseFolderButton))

        typeGoal(app, "Dark mode")

        // Isolation only appears once a folder is chosen — a general session
        // has nothing to isolate.
        XCTAssertTrue(tap(app, .createSessionCheckoutWorktree))
        XCTAssertTrue(tap(app, .createSessionCreateButton))
        XCTAssertTrue(element(app, .createSessionCreateButton).waitForNonExistence(timeout: 5))

        XCTAssertTrue(fastWait(element(app, AXID.sessionRow("Dark mode")), timeout: 3))
        assertWindowIdentity(app, contains: "dark-mode")
    }

    /// The focused session states itself in the window title bar — title, then
    /// project · agent · model · branch from `DetailColumn.identity`. It is the
    /// only place that information appears while a terminal fills the screen.
    private func assertWindowIdentity(
        _ app: XCUIApplication,
        contains needle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let window = app.windows.firstMatch
        let matched = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in window.title.contains(needle) },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [matched], timeout: 5),
            .completed,
            "window title \"\(window.title)\" should contain \"\(needle)\"",
            file: file,
            line: line
        )
    }

    /// The empty-goal case is only reachable through the modal: it allows a
    /// bare interactive agent because opening the window was already a
    /// deliberate action, unlike the always-visible home composer.
    func testModalLauncherAllowsAnEmptyGoal() {
        let app = launchedApp()
        openLauncher(app)

        XCTAssertTrue(fastWait(element(app, .createSessionCreateButton), timeout: 3))
        XCTAssertTrue(element(app, .createSessionCreateButton).isEnabled)
    }

    func testLaunchAndStayLeavesComposerOpen() {
        let app = launchedApp()
        openLauncher(app)

        typeGoal(app, "Background worker")
        XCTAssertTrue(tap(app, .createSessionBackgroundButton))

        // The session row appears in the navigator
        XCTAssertTrue(fastWait(element(app, AXID.sessionRow("Background worker")), timeout: 5))

        // The Session Composer remains open and visible
        XCTAssertTrue(element(app, .createSessionGoalField).exists)
        XCTAssertTrue(element(app, .createSessionBackgroundButton).exists)
    }
}
