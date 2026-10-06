import XCTest
import SessionKit
import CompanionKit
import HooksKit
@testable import Flotilla

/// Screens are copied from Cursor Agent 2026.10.01 in a tmux pane.
@MainActor
final class CursorCompanionAdapterTests: XCTestCase {
    private let idle = """
      READY
      → Add a follow-up
      Auto · 5.4%                                                         Run Everything
      ~/.flotilla/general-session
    """

    private let working = """
     ⠀⠞ Working
        Tip: Use /debug to instrument and debug complex problems.
      → Add a follow-up                                                   ctrl+c to stop
      Auto · 5.4%
    """

    private let shellDialog = """
      Run the shell command `echo hi-from-shell` and then reply DONE2.
      $ echo hi-from-shell Waiting for approval...
    ──────────────────────────────────────────────────────────────────────
     $  echo hi-from-shell in .
     Run this command?
     Not in allowlist: echo
      → Run (once) (y)
        Add Shell(echo) to allowlist? (tab)
        Run Everything (shift+tab)
        Skip & tell the agent what to do instead (esc or n)
                                                          ctrl+r to review changes
    """

    private let fetchDialog = """
        WebFetch https://example.com
    ──────────────────────────────────────────────────────────────────────
     🌐 Web Fetch: https://example.com
     Allow this web fetch?
      → Fetch (y)
        Always allow example.com (tab)
        Skip (esc or n)
    """

    private let skipPrompt = """
     ┌────────────────────────────────────────────────────────────────────
     │ $  echo hook-allowed in .
     └────────────────────────────────────────────────────────────────────
      → Tell the agent what to do instead (Enter to send, empty to skip, Esc to cancel)    ctrl+c
    """

    private func planDialog(path: String) -> String {
        """
         │ # Add English greeting file
         │
         │  Saved to \(path.dropFirst())
         │ ──────────────────────────────────────────────────────────────────
         │
         │ Ready to build?
         │
         │  → 1. Yes, build locally (b)
         │    2. Yes, build in cloud (c)
         │    3. No, propose changes (p or Esc)
         │
         └────────────────────────────────────────────────────────────────────
        """
    }

    private final class Terminal {
        var screen: String
        var sent: [Data] = []
        var delivered: [String] = []
        /// Screens shown after a key, keyed by that key.
        var after: [Data: String] = [:]

        init(_ screen: String) { self.screen = screen }
    }

    private var support: URL!

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support.appendingPathComponent("hooks"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: support)
    }

    private func makeSession() -> Session {
        Session(
            title: "Cursor session",
            goal: "Goal",
            agent: .cursorAgent,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working
        )
    }

    private func makeAdapter(_ terminal: Terminal, session: Session? = nil) -> CursorCompanionAdapter {
        CursorCompanionAdapter(
            session: session ?? makeSession(),
            support: support,
            plans: support.appendingPathComponent("plans"),
            screen: { _ in terminal.screen },
            send: { data in
                terminal.sent.append(data)
                if let next = terminal.after[data] { terminal.screen = next }
            },
            deliver: { terminal.delivered.append($0) }
        )
    }

    // MARK: - Reading the screen

    func testShellApprovalBecomesAPermissionCard() async throws {
        let adapter = makeAdapter(Terminal(shellDialog))
        try await adapter.refresh()
        guard case .permission(let request)? = adapter.pending.first?.kind else {
            return XCTFail("expected a permission card, got \(adapter.pending)")
        }
        XCTAssertEqual(request.tool, "Shell")
        XCTAssertEqual(request.summary, "echo hi-from-shell")
        XCTAssertEqual(request.allowsAlwaysAllow, true)
    }

    func testWebFetchApprovalBecomesAPermissionCard() async throws {
        let adapter = makeAdapter(Terminal(fetchDialog))
        try await adapter.refresh()
        guard case .permission(let request)? = adapter.pending.first?.kind else {
            return XCTFail("expected a permission card")
        }
        XCTAssertEqual(request.tool, "WebFetch")
        XCTAssertEqual(request.summary, "https://example.com")
    }

    func testPlanDialogBecomesAPlanCardWithTheSavedPlan() async throws {
        let plans = support.appendingPathComponent("plans")
        try FileManager.default.createDirectory(at: plans, withIntermediateDirectories: true)
        let file = plans.appendingPathComponent("greeting-dd6f1116.plan.md")
        try Data("""
        <!-- dd6f1116 -->
        ---
        todos:
          - id: "create"
            status: pending
        ---
        # Add English greeting file

        Create c.txt.
        """.utf8).write(to: file)
        let adapter = makeAdapter(Terminal(planDialog(path: file.path)))
        try await adapter.refresh()
        guard case .plan(let plan)? = adapter.pending.first?.kind else {
            return XCTFail("expected a plan card, got \(adapter.pending)")
        }
        XCTAssertEqual(plan.title, "Add English greeting file")
        XCTAssertEqual(plan.markdown, "# Add English greeting file\n\nCreate c.txt.")
    }

    func testNoCardWhileIdleWorkingOrTypingAtTheMac() async throws {
        for screen in [idle, working, skipPrompt] {
            let adapter = makeAdapter(Terminal(screen))
            try await adapter.refresh()
            XCTAssertTrue(adapter.pending.isEmpty, screen)
        }
    }

    func testTheSameDialogKeepsItsCard() async throws {
        let terminal = Terminal(shellDialog)
        let adapter = makeAdapter(terminal)
        try await adapter.refresh()
        let first = try XCTUnwrap(adapter.pending.first?.id)
        try await adapter.refresh()
        XCTAssertEqual(adapter.pending.first?.id, first)
        terminal.screen = idle
        try await adapter.refresh()
        XCTAssertTrue(adapter.pending.isEmpty)
    }

    func testComposerDraftIgnoresPlaceholders() {
        XCTAssertNil(CursorCompanionAdapter.composerDraft(in: "  → Plan, search, build anything\n  Auto"))
        XCTAssertNil(CursorCompanionAdapter.composerDraft(in: working))
        XCTAssertNil(CursorCompanionAdapter.composerDraft(in: "  → Add a follow-up — /plan to review and build\n  Plan"))
        XCTAssertNil(CursorCompanionAdapter.composerDraft(in: "❯ "))
        XCTAssertEqual(
            CursorCompanionAdapter.composerDraft(in: "  A → B in the reply\n  → draft text here\n  Auto"),
            "draft text here"
        )
    }

    // MARK: - Answering

    private func answer(_ answer: InteractionAnswer, on screen: String, after: [Data: String] = [:]) async throws -> Terminal {
        let terminal = Terminal(screen)
        terminal.after = after
        let adapter = makeAdapter(terminal)
        try await adapter.refresh()
        let card = try XCTUnwrap(adapter.pending.first)
        let outcome = try await adapter.answer(card.id, with: answer)
        XCTAssertEqual(outcome, .accepted)
        XCTAssertTrue(adapter.pending.isEmpty)
        return terminal
    }

    func testApprovalAnswersPressCursorsKeys() async throws {
        var terminal = try await answer(.allow, on: shellDialog)
        XCTAssertEqual(terminal.sent, [Data("y".utf8)])

        terminal = try await answer(.alwaysAllow, on: shellDialog)
        XCTAssertEqual(terminal.sent, [Data("\t".utf8)])

        terminal = try await answer(.allowWithNote("then run the tests"), on: shellDialog)
        XCTAssertEqual(terminal.sent, [Data("y".utf8)])
        XCTAssertEqual(terminal.delivered, ["then run the tests"])
    }

    func testDenyAnswersTheSkipPrompt() async throws {
        var terminal = try await answer(.deny, on: shellDialog, after: [Data("n".utf8): skipPrompt])
        XCTAssertEqual(terminal.sent, [Data("n".utf8), Data("\r".utf8)])

        terminal = try await answer(.denyWithNote("use make test"), on: shellDialog, after: [Data("n".utf8): skipPrompt])
        XCTAssertEqual(terminal.sent, [Data("n".utf8)])
        XCTAssertEqual(terminal.delivered, ["use make test"])
    }

    /// A web fetch skips on `n` without asking why; the note follows as a prompt.
    func testDenyWithNoteOnAWebFetchSendsTheNoteAsAPrompt() async throws {
        let terminal = try await answer(.denyWithNote("no network"), on: fetchDialog, after: [Data("n".utf8): working])
        XCTAssertEqual(terminal.sent, [Data("n".utf8)])
        XCTAssertEqual(terminal.delivered, ["no network"])
    }

    /// In a dialog Ctrl-C only rejects the call and the turn goes on; the
    /// second Ctrl-C, once Cursor works again, ends the turn.
    func testDenyAndStopRejectsThenInterrupts() async throws {
        let terminal = Terminal(shellDialog)
        let adapter = makeAdapter(terminal)
        try await adapter.refresh()
        let card = try XCTUnwrap(adapter.pending.first)
        // First Ctrl-C: dialog gone, still working. Second: idle.
        terminal.after[Data([0x03])] = working
        let task = Task { try await adapter.answer(card.id, with: .denyAndStop) }
        while terminal.sent.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        terminal.after[Data([0x03])] = idle
        let outcome = try await task.value
        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(terminal.sent.filter { $0 == Data([0x03]) }.count, 2)
    }

    /// The rejected call can end the turn by itself; a second Ctrl-C would
    /// then arm "Press Ctrl+C again to exit".
    func testDenyAndStopSendsNoSecondControlCWhenTheTurnAlreadyEnded() async throws {
        let terminal = try await answer(.denyAndStop, on: shellDialog, after: [Data([0x03]): idle])
        XCTAssertEqual(terminal.sent, [Data([0x03])])
    }

    func testPlanAnswers() async throws {
        let dialog = planDialog(path: "/nowhere/x.plan.md")
        var terminal = try await answer(.approvePlan(nil), on: dialog)
        XCTAssertEqual(terminal.sent, [Data("b".utf8)])

        let revising = "  → Describe how to revise the plan (Enter to submit, Esc to cancel)"
        terminal = try await answer(.revisePlan("Say hello there"), on: dialog, after: [Data("p".utf8): revising])
        XCTAssertEqual(terminal.sent, [Data("p".utf8)])
        XCTAssertEqual(terminal.delivered, ["Say hello there"])
    }

    /// Answered at the Mac first: no keys may reach the composer.
    func testAnswerAfterTheMacAnsweredTypesNothing() async throws {
        let terminal = Terminal(shellDialog)
        let adapter = makeAdapter(terminal)
        try await adapter.refresh()
        let card = try XCTUnwrap(adapter.pending.first)
        terminal.screen = working
        let outcome = try await adapter.answer(card.id, with: .allow)
        XCTAssertEqual(outcome, .alreadyAnswered)
        XCTAssertTrue(terminal.sent.isEmpty)
    }

    // MARK: - Prompts and Stop

    /// A phone prompt must be *submitted* via the tmux-backed delivery path.
    func testSendPromptSubmitsThroughReliableDelivery() async throws {
        let terminal = Terminal(idle)
        try await makeAdapter(terminal).sendPrompt("Fix the flaky test")
        XCTAssertEqual(terminal.delivered, ["Fix the flaky test"])
        // Nothing goes over the raw channel: Cursor types Ctrl-S as a literal
        // "s", which used to prefix phone prompts ("sCommit this to main").
        XCTAssertTrue(terminal.sent.isEmpty)
    }

    private func followupQueue(for session: Session) -> URL {
        URL(fileURLWithPath: HookConfigurationWriter.eventFilePath(for: session.id, supportDirectory: support).path
            + HookConfigurationWriter.cursorFollowupSuffix)
    }

    /// Mid-turn, a phone prompt waits for the turn's `stop` hook, which
    /// hands it to Cursor as `followup_message` — no keys go into a composer
    /// the person at the Mac may be typing in.
    func testPromptSentMidTurnWaitsForTheStopHookInsteadOfTyping() async throws {
        let session = makeSession()
        let terminal = Terminal(working)
        let adapter = makeAdapter(terminal, session: session)
        try await adapter.sendPrompt("Also run the tests")
        try await adapter.sendPrompt("Then commit")

        XCTAssertTrue(terminal.delivered.isEmpty)
        XCTAssertTrue(terminal.sent.isEmpty)
        XCTAssertEqual(try String(contentsOf: followupQueue(for: session), encoding: .utf8), "Also run the tests\n\nThen commit")
    }

    /// A turn that ended without a completed `stop` (interrupted, failed, or
    /// just before the prompt was queued) must not strand the prompt.
    func testQueuedPromptIsTypedOnceThePaneIsIdleWithoutADraft() async throws {
        let session = makeSession()
        try Data("Also run the tests".utf8).write(to: followupQueue(for: session))
        let draft = Terminal("  OK\n  → half-typed thought\n  Auto · 5.8%")
        try await makeAdapter(draft, session: session).refresh()
        XCTAssertTrue(draft.delivered.isEmpty, "a Mac draft would be sent glued to the prompt")

        let terminal = Terminal(idle)
        let adapter = makeAdapter(terminal, session: session)
        try await adapter.refresh()
        try await adapter.refresh()
        XCTAssertEqual(terminal.delivered, ["Also run the tests"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: followupQueue(for: session).path))
    }

    func testSendPromptRejectedWhileADialogOrDraftIsOpen() async {
        for screen in [shellDialog, skipPrompt, "  OK\n  → half-typed thought\n  Auto · 5.8%"] {
            let terminal = Terminal(screen)
            do {
                try await makeAdapter(terminal).sendPrompt("Go ahead")
                XCTFail("should be rejected: \(screen)")
            } catch {}
            XCTAssertTrue(terminal.delivered.isEmpty)
        }
    }

    /// Escape doesn't interrupt Cursor; Ctrl-C does, and Cursor then puts the
    /// interrupted prompt back into the composer.
    func testStopSendsOneControlCAndClearsTheRestoredPrompt() async throws {
        let terminal = Terminal(working)
        let restored = "  → Write a 600-line poem about mountains\n  Auto · 7.6%"
        terminal.after = [Data([0x03]): restored, Data([0x15]): idle]
        try await makeAdapter(terminal).stop()
        XCTAssertEqual(terminal.sent.first, Data([0x03]))
        XCTAssertEqual(terminal.sent.filter { $0 == Data([0x03]) }.count, 1)
        XCTAssertTrue(terminal.sent.contains(Data([0x15])))
    }

    /// Ctrl-C on an idle composer arms "Press Ctrl+C again to exit".
    func testStopWhileIdleSendsNothing() async throws {
        let terminal = Terminal(idle)
        try await makeAdapter(terminal).stop()
        XCTAssertTrue(terminal.sent.isEmpty)
    }
}
