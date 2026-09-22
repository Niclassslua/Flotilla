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
        // The raw channel carries only the draft-stash keystroke, never the
        // prompt text.
        XCTAssertEqual(sentBytes, [Data([0x13])])
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
