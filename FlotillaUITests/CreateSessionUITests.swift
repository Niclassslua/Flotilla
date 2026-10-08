import XCTest
import AppKit

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
        // The agent is asserted on the session bar rather than the row.
        // Navigator rows carry status and churn only now — the agent is the
        // provider tile beside the title.
        assertSessionBar(app, AXID.sessionBarHandoff("Flaky CI"), contains: "Codex CLI")

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
        assertSessionBar(app, AXID.sessionBarBranch("Dark mode"), contains: "dark-mode")
    }

    /// The focused session states its agent and branch in the session bar;
    /// the window title carries only the session title (`DetailColumn`).
    private func assertSessionBar(
        _ app: XCUIApplication,
        _ identifier: String,
        contains needle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let item = element(app, identifier)
        func text() -> String { "\(item.title) \(item.label) \(item.value as? String ?? "")" }
        let deadline = Date().addingTimeInterval(5)
        while !(item.exists && text().contains(needle)), Date() < deadline { usleep(100_000) }
        XCTAssertTrue(
            item.exists && text().contains(needle),
            "\(identifier) should contain \"\(needle)\": \(item.exists ? item.debugDescription : "missing")",
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

    // MARK: - Pasting images

    /// The goal field's field editor ignores image data, so ⌘V with a
    /// screenshot on the clipboard only works through `ImagePasteCatcher`'s
    /// key monitor — wiring that silently breaks if the monitor is removed or
    /// starts swallowing text pastes.
    func testCommandVAttachesAClipboardImageButStillPastesText() {
        let saved = savePasteboard()
        defer { restorePasteboard(saved) }

        let app = launchedApp()
        openLauncher(app)
        element(app, .createSessionGoalField).click()

        setPasteboardImage()
        element(app, .createSessionGoalField).typeKey("v", modifierFlags: .command)
        XCTAssertTrue(fastWait(element(app, .createSessionAttachments), timeout: 3))
        XCTAssertEqual(element(app, .createSessionGoalField).value as? String ?? "", "")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Match the screenshot", forType: .string)
        element(app, .createSessionGoalField).typeKey("v", modifierFlags: .command)
        let pasted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Match the screenshot"),
            object: element(app, .createSessionGoalField)
        )
        XCTAssertEqual(XCTWaiter().wait(for: [pasted], timeout: 3), .completed)
    }

    private func setPasteboardImage() {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(rep.representation(using: .png, properties: [:])!, forType: .png)
    }

    /// The test writes to the real clipboard; whoever runs it gets theirs back.
    private func savePasteboard() -> [[NSPasteboard.PasteboardType: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    private func restorePasteboard(_ items: [[NSPasteboard.PasteboardType: Data]]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(items.map { contents in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        })
    }
}
