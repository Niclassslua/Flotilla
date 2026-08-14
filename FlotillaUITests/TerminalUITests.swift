import XCTest

/// Covers Part 0's terminal requirements: sending input and seeing it
/// rendered, and two sessions running concurrently with switching between
/// them preserving state (neither process gets killed by the switch).
///
/// SwiftTerm's own view doesn't expose its content to accessibility, so
/// `TerminalController` manually republishes the buffer text as the
/// terminal NSView's accessibility value on every feed — these tests read
/// that value rather than looking for child text elements. Each terminal's
/// identifier includes the session title (`TerminalView-<title>`) since
/// Grid View can show several mounted at once.
@MainActor
final class TerminalUITests: XCTestCase {
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        return app
    }

    @discardableResult
    private func waitForTerminal(_ app: XCUIApplication, identifier: String, toContain text: String, timeout: TimeInterval = 8) -> Bool {
        let terminal = app.descendants(matching: .any)[identifier].firstMatch
        let predicate = NSPredicate { _, _ in
            (terminal.value as? String)?.contains(text) ?? false
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    func testSendingInputRendersInTerminal() {
        let app = launchedApp()

        let row = app.descendants(matching: .any)["SessionRow-Fix login bug"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.click()

        let terminal = app.descendants(matching: .any)["TerminalView-Fix login bug"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 8))
        terminal.click()

        let marker = "echo-probe-\(UUID().uuidString.prefix(8))"
        app.typeText(marker)

        // The mock agent process echoes input back through the terminal
        // (SessionProcessManager.start enables echoInputToOutput on its
        // "agent not installed" fallback), so the typed marker should
        // reappear in the terminal's own rendered content.
        XCTAssertTrue(waitForTerminal(app, identifier: "TerminalView-Fix login bug", toContain: marker))
    }

    func testSwitchingSessionsKeepsBothRunning() {
        let app = launchedApp()

        let firstRow = app.descendants(matching: .any)["SessionRow-Fix login bug"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 8))
        firstRow.click()

        let firstTerminal = app.descendants(matching: .any)["TerminalView-Fix login bug"].firstMatch
        XCTAssertTrue(firstTerminal.waitForExistence(timeout: 8))
        firstTerminal.click()

        let firstMarker = "session-a-\(UUID().uuidString.prefix(8))"
        app.typeText(firstMarker)
        XCTAssertTrue(waitForTerminal(app, identifier: "TerminalView-Fix login bug", toContain: firstMarker))

        // Switch to a second session and interact with it too.
        let secondRow = app.descendants(matching: .any)["SessionRow-Refactor sidebar"].firstMatch
        XCTAssertTrue(secondRow.waitForExistence(timeout: 8))
        secondRow.click()

        let secondTerminal = app.descendants(matching: .any)["TerminalView-Refactor sidebar"].firstMatch
        XCTAssertTrue(secondTerminal.waitForExistence(timeout: 8))
        secondTerminal.click()

        let secondMarker = "session-b-\(UUID().uuidString.prefix(8))"
        app.typeText(secondMarker)
        XCTAssertTrue(waitForTerminal(app, identifier: "TerminalView-Refactor sidebar", toContain: secondMarker))

        // Switch back to the first session: its earlier output must still
        // be there — proving the process/terminal kept running rather than
        // being torn down while not focused.
        firstRow.click()
        XCTAssertTrue(waitForTerminal(app, identifier: "TerminalView-Fix login bug", toContain: firstMarker))
    }
}
