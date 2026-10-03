import XCTest
import SessionKit
import CompanionKit
@testable import Flotilla

@MainActor
final class CursorCompanionAdapterTests: XCTestCase {
    private func makeSession() -> Session {
        Session(
            title: "Cursor session",
            goal: "Goal",
            agent: .cursorAgent,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .waitingForInput
        )
    }

    /// A phone prompt must be *submitted* via the tmux-backed delivery path.
    /// Regression: the adapter used to write the text and `\r` as one bulk
    /// PTY write, which the Cursor TUI treats as paste content — the prompt
    /// sat typed in the composer and was never sent.
    func testSendPromptSubmitsThroughReliableDelivery() async throws {
        var sentBytes: [Data] = []
        var delivered: [String] = []
        let adapter = CursorCompanionAdapter(
            session: makeSession(),
            bridge: ClaudePermissionBridge(),
            support: FileManager.default.temporaryDirectory,
            screen: { _ in "❯ " },
            send: { sentBytes.append($0) },
            deliver: { delivered.append($0) }
        )

        try await adapter.sendPrompt("Fix the flaky test")

        XCTAssertEqual(delivered, ["Fix the flaky test"])
        // Nothing goes over the raw channel: Cursor types Ctrl-S as a literal
        // "s", which used to prefix phone prompts ("sCommit this to main").
        XCTAssertEqual(sentBytes, [])
    }

    /// Text already in Cursor's composer would be sent glued to the phone's
    /// prompt as one message, so the prompt is rejected instead.
    func testSendPromptRejectedWhileComposerHoldsDraft() async {
        var delivered: [String] = []
        let adapter = CursorCompanionAdapter(
            session: makeSession(),
            bridge: ClaudePermissionBridge(),
            support: FileManager.default.temporaryDirectory,
            screen: { _ in "  OK\n  → half-typed thought\n  Auto · 5.8%" },
            send: { _ in },
            deliver: { delivered.append($0) }
        )

        do {
            try await adapter.sendPrompt("Go ahead")
            XCTFail("The prompt should have been rejected while the composer holds a draft.")
        } catch {
            // Expected: rejected.
        }
        XCTAssertTrue(delivered.isEmpty)
    }

    func testComposerDraftIgnoresPlaceholders() {
        XCTAssertNil(CursorCompanionAdapter.composerDraft(in: "  → Plan, search, build anything\n  Auto"))
        XCTAssertNil(CursorCompanionAdapter.composerDraft(in: "  → Add a follow-up              ctrl+c to stop\n  Auto"))
        XCTAssertNil(CursorCompanionAdapter.composerDraft(in: "❯ "))
        XCTAssertEqual(
            CursorCompanionAdapter.composerDraft(in: "  A → B in the reply\n  → draft text here\n  Auto"),
            "draft text here"
        )
    }

    /// A terminal-local dialog (Run/Skip) must reject the phone prompt so it
    /// isn't delivered behind the dialog's back.
    func testSendPromptRejectedWhileTerminalDialogOpen() async {
        var delivered: [String] = []
        let adapter = CursorCompanionAdapter(
            session: makeSession(),
            bridge: ClaudePermissionBridge(),
            support: FileManager.default.temporaryDirectory,
            screen: { _ in "Run this command? Run Skip" },
            send: { _ in },
            deliver: { delivered.append($0) }
        )

        do {
            try await adapter.sendPrompt("Go ahead")
            XCTFail("The prompt should have been rejected while a dialog is open.")
        } catch {
            // Expected: rejected.
        }
        XCTAssertTrue(delivered.isEmpty)
    }
}
