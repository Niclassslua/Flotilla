import XCTest
import SessionKit
import ProcessKit
@testable import HooksKit

final class SessionStatusHeuristicTests: XCTestCase {
    private let heuristic = SessionStatusHeuristic()

    func testDetectStatusPhrasesAndNonMatches() {
        let waiting = [
            "Do you want to proceed?",
            "Continue? (y/n)",
            "Permission required to write file",
        ]
        for phrase in waiting {
            XCTAssertEqual(heuristic.detectStatus(in: phrase), .waitingForInput, phrase)
        }

        let ignored = [
            "Compiling module SessionKit...",
            "Permission accepted; continuing",
            "",
        ]
        for phrase in ignored {
            XCTAssertNil(heuristic.detectStatus(in: phrase), phrase)
        }
    }
}

final class WaitingNotificationGateTests: XCTestCase {
    func testNotifiesOnlyOnTransitionIntoWaiting() {
        let gate = WaitingNotificationGate()
        XCTAssertTrue(gate.shouldNotify(for: .waitingForInput))
        XCTAssertFalse(gate.shouldNotify(for: .waitingForInput), "still waiting, no repeat")
        XCTAssertFalse(gate.shouldNotify(for: .working))
        XCTAssertTrue(gate.shouldNotify(for: .waitingForInput), "waiting again after leaving")

        let fresh = WaitingNotificationGate()
        for status: SessionStatus in [.working, .readyForReview, .crashed] {
            XCTAssertFalse(fresh.shouldNotify(for: status), "\(status)")
        }
    }
}

final class TerminalScreenHeuristicTests: XCTestCase {
    private let heuristic = TerminalScreenHeuristic()

    /// What Claude Code draws while it is actually doing something: the
    /// interrupt hint is present precisely for the duration of the work.
    private let workingScreen = """
    ● I'll start by reading the sidebar view.

    ● Read(Flotilla/SessionRow.swift)
      ⎿  Read 148 lines

    ✻ Thinking… (12s · ↑ 1.2k tokens · esc to interrupt)
    """

    /// The same session a moment later: work done, composer back, no hint.
    private let idleScreen = """
    ● I updated the beacon so it no longer shifts while pulsing.

    ╭──────────────────────────────────────────╮
    │ > Try "fix the status indicator"         │
    ╰──────────────────────────────────────────╯
      ? for shortcuts
    """

    private let permissionScreen = """
    ● Bash(rm -rf build/)
      ⎿  Running…

    Do you want to proceed?
    ❯ 1. Yes
      2. No, and tell Claude what to do differently
    """

    private let antigravityWorkingScreen = """
    ● Bash(find /Users/test/Flotilla/hooks -name '*.jsonl' -empty | wc -l)
    ⣯  Generating...
    ──────────────────────────────────────────────────────────────
    > Accept-edits mode: file edits auto-approved
    ──────────────────────────────────────────────────────────────
    esc to cancel                              Gemini 3.8 Flash · medium
    """

    private let antigravityPermissionScreen = """
    ● Bash(find '/Users/test/Flotilla/hooks' -name '*.jsonl' -empty | wc -l)
    Command
    ──────────────────────────────────────────────────────────────
    Requesting permission for:
      find /Users/test/Flotilla/hooks -name '*.jsonl' -empty | wc -l

    Run this command?
    > 1. Yes, run command
      2. Yes, and always allow in this conversation for commands that start with
    'find /Users/test/Flotilla/hooks' -name '*.jsonl' -empty
      3. Yes, and always allow for commands that start with 'find
    /Users/test/Flotilla/hooks' -name '*.jsonl' -empty (Persist to settings.json)
      4. No, cancel

      ↑/↓ Navigate · tab Amend · ctrl+g edit/expand command
    esc to cancel                              Gemini 3.8 Flash · medium
    """

    /// A prompt outranks a spinner: some CLIs keep drawing the busy line
    /// underneath a question they are blocked on.
    private let promptWinsOverInterrupt = """
    Do you want to allow this edit?
    ❯ 1. Yes
      2. No
    ✻ Waiting… (esc to interrupt)
    """

    /// Markers still count while they sit within the inspected tail — this
    /// is a heuristic, and its protection is exactly the tail window.
    private var scrolledTranscriptIgnored: String {
        let transcript = (1...12)
            .map { "● Step \($0): the hint reads \"esc to interrupt\", then asks \"Do you want to proceed?\"" }
            .joined(separator: "\n")
        return """
        \(transcript)
        ╭──────────────────────────────────────────╮
        │ > Try "fix the status indicator"         │
        │                                          │
        ╰──────────────────────────────────────────╯
          ? for shortcuts
          ⏵⏵ accept edits on
          main ✱ 3 files changed
          claude-opus-5
        """
    }

    private let numberedListWithoutCaret = """
    Here are the next steps:
    1. Fix the beacon
    2. Fix the status word
    3. Ship it

    │ >                                        │
    """

    private let liveCodexComposer = """
    • Plan implemented and the worktree remains clean.

    ────────────────────────────────────────────
    › Ask Codex to do anything

      gpt-5.6-sol medium · ~/Documents/Projects/SwiftUi/Flotilla
    """

    private let liveClaudeComposer = """
    ⏺ The requested change is complete.
    ✻ Worked for 42s
    ─────────────────────────────── test-plan-mode ─
    ❯ clean up the worktree and branch
    ────────────────────────────────────────────────
    Est. usage: 1 Standard request
    ⏵⏵ auto mode on · 1 file changed
    """

    private let waitingForInputProseWhileWorking = """
    ● The toggle is labeled "Agent is waiting for input".
    ⣯  Generating...
    ──────────────────────────────────────────────────────────────
    esc to cancel                              Gemini 3.8 Flash · medium
    """

    private let waitingForInputProseWithComposer = """
    ● The toggle you added is "Agent is waiting for input".
    ╭──────────────────────────────────────────╮
    │ > Try "fix the status indicator"         │
    ╰──────────────────────────────────────────╯
      ? for shortcuts
    """

    private let unremarkableScreen = """
    Claude Code v1.0.0
    Connected to workspace
    Building dependencies...
    """

    private let emptyComposerOnly = """
    ╭──────────────────────────────────────────╮
    │ >                                        │
    ╰──────────────────────────────────────────╯
    """

    func testScreenStatusClassification() {
        let cases: [(name: String, screen: String, expected: SessionStatus?)] = [
            ("interrupt hint means working", workingScreen, .working),
            ("antigravity cancel hint means working", antigravityWorkingScreen, .working),
            ("composer with provider footer means ready", idleScreen, .readyForReview),
            ("prompt wins over simultaneous interrupt hint", promptWinsOverInterrupt, .waitingForInput),
            ("transcript scrolled above status area is ignored", scrolledTranscriptIgnored, .readyForReview),
            ("numbered list without selection caret is not waiting", numberedListWithoutCaret, .readyForReview),
            ("live codex composer with footer means ready", liveCodexComposer, .readyForReview),
            ("live claude composer with several footers means ready", liveClaudeComposer, .readyForReview),
            ("prose 'waiting for input' while working stays working", waitingForInputProseWhileWorking, .working),
            ("prose 'waiting for input' with composer is ready", waitingForInputProseWithComposer, .readyForReview),
            ("unremarkable screen without markers", unremarkableScreen, nil),
            ("composer prompt without transcript", emptyComposerOnly, nil),
        ]

        for entry in cases {
            XCTAssertEqual(heuristic.status(forScreen: entry.screen), entry.expected, entry.name)
        }
    }

    func testWaitingObservationsCarryReason() {
        let cases: [(name: String, screen: String, expected: SessionStatusObservation?)] = [
            ("permission prompt", permissionScreen, SessionStatusObservation(.waitingForInput, waitingReason: .permission)),
            ("antigravity requesting permission wording", antigravityPermissionScreen, SessionStatusObservation(.waitingForInput, waitingReason: .permission)),
            ("codex question", """
            Question 1/1 (1 unanswered)
            Which approach should I take?
            ❯ 1. Keep compatibility
              2. Simplify the API
            """, SessionStatusObservation(.waitingForInput, waitingReason: .question)),
            ("plan approval", """
            Proposed Plan
            1. Update the model
            2. Wire the UI
            Approve this plan?
            """, SessionStatusObservation(.waitingForInput, waitingReason: .planApproval)),
            ("unremarkable", unremarkableScreen, nil),
            ("empty composer", emptyComposerOnly, nil),
        ]

        for entry in cases {
            XCTAssertEqual(heuristic.observation(forScreen: entry.screen), entry.expected, entry.name)
        }
    }

    /// An agent that dies mid-prompt leaves the prompt drawn above tmux's
    /// banner. Read as waiting, the session would never get its exit screen
    /// and would sit in Needs You with nobody to answer.
    func testDeadPaneBannerOutranksAStalePromptAboveIt() {
        let screen = permissionScreen + "\n\n[Agent exited with status 1]"

        let observation = heuristic.observation(forScreen: screen)

        XCTAssertEqual(observation?.status, .readyForReview)
        XCTAssertEqual(observation?.suggestsAgentExit, true)
        XCTAssertEqual(heuristic.observation(forScreen: permissionScreen)?.suggestsAgentExit, false)
    }
}

final class SessionScreenMonitorTests: XCTestCase {
    /// Hands out a scripted sequence of screens, one per poll, repeating the
    /// last one forever — the way a real session holds a screen until
    /// something changes it.
    private actor ScriptedScreenReader: SessionScreenReading {
        private let screens: [String?]
        private var index = 0
        private(set) var readCount = 0

        init(_ screens: [String?]) { self.screens = screens }

        func readScreen(for sessionID: UUID) async -> String? {
            readCount += 1
            let screen = screens[min(index, screens.count - 1)]
            index += 1
            return screen
        }
    }

    private func collect(
        from monitor: SessionScreenMonitor,
        settling: Duration = .milliseconds(400)
    ) async -> [SessionStatusObservation] {
        let statuses = ObservationBox()
        let collector = Task {
            for await observation in monitor.observationStream { await statuses.append(observation) }
        }
        monitor.start()
        try? await Task.sleep(for: settling)
        monitor.stop()
        collector.cancel()
        return await statuses.values
    }

    private actor ObservationBox {
        private(set) var values: [SessionStatusObservation] = []
        func append(_ observation: SessionStatusObservation) { values.append(observation) }
    }

    func testScreenMonitorDedupesRedrawsAndFollowsTransitions() async {
        let readyScreen = "● Done.\n> ready"
        let stableReader = ScriptedScreenReader([readyScreen, readyScreen, readyScreen, readyScreen])
        let stable = SessionScreenMonitor(
            sessionID: UUID(),
            reader: stableReader,
            pollInterval: .milliseconds(30)
        )
        let stableObserved = await collect(from: stable)
        XCTAssertEqual(stableObserved, [SessionStatusObservation(.readyForReview)])
        let readCount = await stableReader.readCount
        XCTAssertGreaterThan(readCount, 1, "the monitor should have polled repeatedly")

        let unremarkable = SessionScreenMonitor(
            sessionID: UUID(),
            reader: ScriptedScreenReader([
                "Claude Code v1.0.0\nInitializing...",
                "Claude Code v1.0.0\nReading repository...",
            ]),
            pollInterval: .milliseconds(30)
        )
        let unremarkableObserved = await collect(from: unremarkable)
        XCTAssertTrue(unremarkableObserved.isEmpty, "screens without markers must not produce status updates")

        let frames = ["✻", "✢", "·", "✳"].map { "\($0) Thinking… (esc to interrupt)" }
        let spinner = SessionScreenMonitor(
            sessionID: UUID(),
            reader: ScriptedScreenReader(frames),
            pollInterval: .milliseconds(30)
        )
        let spinnerObserved = await collect(from: spinner)
        XCTAssertEqual(spinnerObserved, [SessionStatusObservation(.working)])

        let transition = SessionScreenMonitor(
            sessionID: UUID(),
            reader: ScriptedScreenReader([
                "✻ Thinking… (esc to interrupt)",
                "✻ Thinking… (esc to interrupt)",
                "● Done.\n│ > │\n  ? for shortcuts",
            ]),
            pollInterval: .milliseconds(30)
        )
        let transitionObserved = await collect(from: transition)
        XCTAssertEqual(
            transitionObserved,
            [SessionStatusObservation(.working), SessionStatusObservation(.readyForReview)]
        )

        let unreadable = SessionScreenMonitor(
            sessionID: UUID(),
            reader: ScriptedScreenReader([nil]),
            pollInterval: .milliseconds(30)
        )
        let unreadableObserved = await collect(from: unreadable)
        XCTAssertTrue(unreadableObserved.isEmpty)
    }
}

final class NotificationDispatchingTests: XCTestCase {
    private final class RecordingDispatcher: NotificationDispatching, @unchecked Sendable {
        private(set) var notifiedTitles: [String] = []
        func notifyWaitingForInput(sessionTitle: String, sessionID: UUID) async {
            notifiedTitles.append(sessionTitle)
        }
        func notifySessionFinished(sessionTitle: String, sessionID: UUID) async {}
    }

    private final class StaticScreenReader: SessionScreenReading, @unchecked Sendable {
        private let screen: String
        init(_ screen: String) { self.screen = screen }
        func readScreen(for sessionID: UUID) async -> String? { screen }
    }

    /// End-to-end wiring test: monitor -> gate -> dispatcher, mirroring how
    /// the App-layer HookCoordinator composes these three pieces. The
    /// prompt stays on screen across many polls and must notify once.
    func testFullPipelineNotifiesExactlyOnceForOneWaitingEpisode() async throws {
        let monitor = SessionScreenMonitor(
            sessionID: UUID(),
            reader: StaticScreenReader("Do you want to proceed?\n❯ 1. Yes\n  2. No"),
            pollInterval: .milliseconds(30)
        )
        let gate = WaitingNotificationGate()
        let dispatcher = RecordingDispatcher()

        let collectorTask = Task {
            for await observation in monitor.observationStream {
                if gate.shouldNotify(for: observation.status) {
                    await dispatcher.notifyWaitingForInput(sessionTitle: "Test Session", sessionID: UUID())
                }
            }
        }
        monitor.start()
        try await Task.sleep(for: .milliseconds(300))
        monitor.stop()
        collectorTask.cancel()

        XCTAssertEqual(dispatcher.notifiedTitles, ["Test Session"])
    }
}

final class HookEventReceiverTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("flotilla-hook-tests-\(UUID().uuidString).jsonl")
    }

    private func collect(
        from receiver: HookEventReceiver,
        settling: Duration = .milliseconds(500)
    ) async -> [SessionStatusObservation] {
        let statuses = ObservationBox()
        let collector = Task {
            for await observation in receiver.observationStream { await statuses.append(observation) }
        }
        receiver.start()
        try? await Task.sleep(for: settling)
        receiver.stop()
        collector.cancel()
        return await statuses.values
    }

    private actor ObservationBox {
        private(set) var values: [SessionStatusObservation] = []
        func append(_ observation: SessionStatusObservation) { values.append(observation) }
    }

    private func append(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    func testMapsEachKnownEventNameToItsStatusInArrivalOrder() async throws {
        let file = tempFile()
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }

        let receiver = HookEventReceiver(filePath: file, agent: .claudeCode, pollInterval: .milliseconds(30))
        let statuses = ObservationBox()
        let collector = Task {
            for await observation in receiver.observationStream { await statuses.append(observation) }
        }
        receiver.start()
        try await Task.sleep(for: .milliseconds(60))
        try append(#"{"hook_event_name":"PostToolUse","session_id":"abc"}"#, to: file)
        try await Task.sleep(for: .milliseconds(80))
        try append(#"{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude Code needs your approval for the plan","session_id":"abc"}"#, to: file)
        try await Task.sleep(for: .milliseconds(80))
        try append(#"{"hook_event_name":"Stop","session_id":"abc"}"#, to: file)
        try await Task.sleep(for: .milliseconds(150))
        receiver.stop()
        collector.cancel()

        let observed = await statuses.values
        XCTAssertEqual(observed, [
            SessionStatusObservation(.working),
            SessionStatusObservation(.waitingForInput, waitingReason: .planApproval),
            SessionStatusObservation(.readyForReview),
        ])
    }

    func testIgnoresUnknownEventNamesAndMalformedLines() async throws {
        let file = tempFile()
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }

        try append(#"{"hook_event_name":"SomeFutureEvent"}"#, to: file)
        try append("not json at all", to: file)
        try append(#"{"hook_event_name":"Stop"}"#, to: file)

        let receiver = HookEventReceiver(filePath: file, agent: .claudeCode, pollInterval: .milliseconds(30))
        let observed = await collect(from: receiver, settling: .milliseconds(200))

        XCTAssertEqual(observed, [SessionStatusObservation(.readyForReview)])
    }

    func testMissingFileYieldsNothingRatherThanCrashing() async {
        let receiver = HookEventReceiver(
            filePath: FileManager.default.temporaryDirectory.appendingPathComponent("flotilla-hook-tests-does-not-exist.jsonl"),
            agent: .claudeCode,
            pollInterval: .milliseconds(30)
        )
        let observed = await collect(from: receiver, settling: .milliseconds(150))
        XCTAssertTrue(observed.isEmpty)
    }

    func testBuffersSplitUTF8ScalarsUntilTheLineIsComplete() async throws {
        let file = tempFile()
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }

        let receiver = HookEventReceiver(filePath: file, agent: .claudeCode, pollInterval: .milliseconds(30))
        let statuses = ObservationBox()
        let collector = Task {
            for await observation in receiver.observationStream { await statuses.append(observation) }
        }
        receiver.start()

        let complete = Data(#"{"message":"Grüße","hook_event_name":"Stop"}"#.utf8)
        let split = try XCTUnwrap(complete.firstIndex(of: 0xC3)) + 1
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: complete.prefix(split))
        try await Task.sleep(for: .milliseconds(80))
        try handle.write(contentsOf: complete.dropFirst(split) + Data([0x0A]))
        try handle.close()
        try await Task.sleep(for: .milliseconds(150))

        receiver.stop()
        collector.cancel()
        let observed = await statuses.values
        XCTAssertEqual(observed, [SessionStatusObservation(.readyForReview)])
    }

    func testAtomicReplacementResetsOffsetEvenWhenNewFileIsLarger() async throws {
        let file = tempFile()
        try Data((String(repeating: "x", count: 80) + "\n").utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let receiver = HookEventReceiver(filePath: file, agent: .claudeCode, pollInterval: .milliseconds(30))
        let statuses = ObservationBox()
        let collector = Task {
            for await observation in receiver.observationStream { await statuses.append(observation) }
        }
        receiver.start()
        try await Task.sleep(for: .milliseconds(80))

        let replacement = Array(repeating: #"{"hook_event_name":"Stop"}"#, count: 6)
            .joined(separator: "\n") + "\n"
        XCTAssertGreaterThan(replacement.utf8.count, 80)
        try Data(replacement.utf8).write(to: file, options: .atomic)
        try await Task.sleep(for: .milliseconds(180))

        receiver.stop()
        collector.cancel()
        let observed = await statuses.values
        XCTAssertEqual(observed, Array(repeating: SessionStatusObservation(.readyForReview), count: 6))
    }

    func testAntigravityPreToolUseAskQuestionMeansWaitingForInput() async throws {
        let file = tempFile()
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }

        try append(#"{"event":"PreToolUse","payload":{"toolCall":{"name":"ask_question"}}}"#, to: file)
        try append(#"{"event":"PreToolUse","payload":{"toolCall":{"name":"run_command"}}}"#, to: file)
        try append(#"{"event":"PostToolUse","payload":{"toolCall":{"name":"ask_question"}}}"#, to: file)

        let receiver = HookEventReceiver(filePath: file, agent: .antigravity, pollInterval: .milliseconds(30))
        let observed = await collect(from: receiver, settling: .milliseconds(200))

        XCTAssertEqual(observed, [
            SessionStatusObservation(.waitingForInput, waitingReason: .question),
            SessionStatusObservation(.working),
            SessionStatusObservation(.working),
        ])
    }

    func testAntigravityStopOnlyMeansReadyWhenFullyIdle() async throws {
        let file = tempFile()
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }

        try append(#"{"event":"Stop","payload":{"fullyIdle":false}}"#, to: file)
        try append(#"{"event":"Stop","payload":{"fullyIdle":true}}"#, to: file)

        let receiver = HookEventReceiver(filePath: file, agent: .antigravity, pollInterval: .milliseconds(30))
        let observed = await collect(from: receiver, settling: .milliseconds(200))

        XCTAssertEqual(observed, [SessionStatusObservation(.readyForReview)], "fullyIdle: false must not emit any status")
    }

    func testAntigravityPlanArtifactMeansPlanReady() async throws {
        let file = tempFile()
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }

        try append(
            #"{"event":"PostToolUse","payload":{"toolCall":{"name":"write_to_file","args":{"ArtifactMetadata":{"RequestFeedback":true}}}}}"#,
            to: file
        )

        let receiver = HookEventReceiver(filePath: file, agent: .antigravity, pollInterval: .milliseconds(30))
        let observed = await collect(from: receiver, settling: .milliseconds(200))

        XCTAssertEqual(
            observed,
            [SessionStatusObservation(.waitingForInput, waitingReason: .planApproval)]
        )
    }

    func testClaudeDistinguishesIdlePermissionQuestionAndPlan() async throws {
        let file = tempFile()
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }

        try append(#"{"hook_event_name":"Notification","notification_type":"idle_prompt"}"#, to: file)
        try append(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#, to: file)
        try append(#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}"#, to: file)
        try append(#"{"hook_event_name":"PreToolUse","tool_name":"ExitPlanMode"}"#, to: file)

        let receiver = HookEventReceiver(filePath: file, agent: .claudeCode, pollInterval: .milliseconds(30))
        let observed = await collect(from: receiver, settling: .milliseconds(200))

        XCTAssertEqual(observed, [
            SessionStatusObservation(.readyForReview),
            SessionStatusObservation(.waitingForInput, waitingReason: .permission),
            SessionStatusObservation(.waitingForInput, waitingReason: .question),
            SessionStatusObservation(.waitingForInput, waitingReason: .planApproval),
        ])
    }

    func testCodexMapsDocumentedLifecycleEvents() async throws {
        let file = tempFile()
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }

        try append(#"{"hook_event_name":"PreToolUse","tool_name":"request_user_input"}"#, to: file)
        try append(#"{"hook_event_name":"PostToolUse"}"#, to: file)
        try append(#"{"hook_event_name":"PermissionRequest"}"#, to: file)
        try append(#"{"hook_event_name":"Stop","last_assistant_message":null}"#, to: file)
        try append(#"{"hook_event_name":"Stop","last_assistant_message":"Done"}"#, to: file)

        let receiver = HookEventReceiver(filePath: file, agent: .codexCLI, pollInterval: .milliseconds(30))
        let observed = await collect(from: receiver, settling: .milliseconds(200))

        XCTAssertEqual(observed, [
            SessionStatusObservation(.waitingForInput, waitingReason: .question),
            SessionStatusObservation(.working),
            SessionStatusObservation(.waitingForInput, waitingReason: .permission),
            SessionStatusObservation(.waitingForInput, waitingReason: .planApproval),
            SessionStatusObservation(.readyForReview),
        ])
    }

    func testOpenCodeMapsEventsIncludingTheSessionIdleNamingTrap() async throws {
        let file = tempFile()
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }

        try append(#"{"event":"tool.execute.after"}"#, to: file)
        try append(#"{"event":"permission.asked"}"#, to: file)
        try append(#"{"event":"question.asked"}"#, to: file)
        // session.idle means Flotilla's .ready, not .idle — see
        // HookConfigurationWriter's top-level doc comment.
        try append(#"{"event":"session.idle"}"#, to: file)

        let receiver = HookEventReceiver(filePath: file, agent: .openCode, pollInterval: .milliseconds(30))
        let observed = await collect(from: receiver, settling: .milliseconds(200))

        XCTAssertEqual(observed, [
            SessionStatusObservation(.working),
            SessionStatusObservation(.waitingForInput, waitingReason: .permission),
            SessionStatusObservation(.waitingForInput, waitingReason: .question),
            SessionStatusObservation(.readyForReview),
        ])
    }

    /// Cursor's interactive CLI ends a turn with `afterAgentResponse` then
    /// `stop` (verified against agent 2026.10.01). Either must land Ready
    /// for Review; `beforeSubmitPrompt` starts the next working turn.
    func testCursorMapsTurnLifecycleToReadyForReview() async throws {
        let file = tempFile()
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }

        try append(
            #"{"flotilla_provider":"cursor","hook_event_name":"beforeSubmitPrompt","payload":{"prompt":"hi"}}"#,
            to: file
        )
        try append(
            #"{"flotilla_provider":"cursor","hook_event_name":"preToolUse","payload":{"tool_name":"Shell"}}"#,
            to: file
        )
        try append(
            #"{"flotilla_provider":"cursor","hook_event_name":"afterAgentResponse","payload":{"text":"done","status":null}}"#,
            to: file
        )
        try append(
            #"{"flotilla_provider":"cursor","hook_event_name":"stop","payload":{"status":"completed","loop_count":0}}"#,
            to: file
        )

        let receiver = HookEventReceiver(filePath: file, agent: .cursorAgent, pollInterval: .milliseconds(30))
        let observed = await collect(from: receiver, settling: .milliseconds(200))

        XCTAssertEqual(observed, [
            SessionStatusObservation(.working),
            SessionStatusObservation(.working),
            SessionStatusObservation(.readyForReview),
            SessionStatusObservation(.readyForReview),
        ])
    }
}

final class SessionStatusObservationArbiterTests: XCTestCase {
    /// A structured waiting hook is not undone by the screen falling back to
    /// a bare Ready for Review because it did not recognise the prompt.
    func testHookWaitingSurvivesAmbiguousScreenReadyForReview() {
        var arbiter = SessionStatusObservationArbiter()
        let permission = SessionStatusObservation(.waitingForInput, waitingReason: .permission)
        XCTAssertEqual(arbiter.accept(permission, from: .hook), permission)
        XCTAssertNil(arbiter.accept(SessionStatusObservation(.readyForReview), from: .screen))
    }

    func testHookPlanReadySurvivesScreenFallbackUntilWorkResumes() {
        var arbiter = SessionStatusObservationArbiter()
        let planReady = SessionStatusObservation(.waitingForInput, waitingReason: .planApproval)
        XCTAssertEqual(arbiter.accept(planReady, from: .hook), planReady)
        // A screen that only sees a composer must not drop Plan Ready.
        XCTAssertNil(arbiter.accept(SessionStatusObservation(.readyForReview), from: .screen))
        // A different, screen-guessed waiting reason is held off too.
        XCTAssertNil(
            arbiter.accept(
                SessionStatusObservation(.waitingForInput, waitingReason: .question),
                from: .screen
            )
        )
        // Visible work is a new episode: it, and everything after it, stands.
        XCTAssertEqual(
            arbiter.accept(SessionStatusObservation(.working), from: .screen),
            SessionStatusObservation(.working)
        )
        XCTAssertEqual(
            arbiter.accept(SessionStatusObservation(.readyForReview), from: .screen),
            SessionStatusObservation(.readyForReview)
        )
    }

    func testHookWorkingSurvivesAmbiguousAntigravityRedrawUntilStop() {
        var arbiter = SessionStatusObservationArbiter(sessionHasProgressed: true)
        let working = SessionStatusObservation(.working, cause: "hook: PostToolUse run_command")
        XCTAssertEqual(arbiter.accept(working, from: .hook), working)

        XCTAssertNil(
            arbiter.accept(
                SessionStatusObservation(.readyForReview, cause: "screen: no marker matched — default"),
                from: .screen
            ),
            "a transient Antigravity redraw between tool calls must not end the working episode"
        )

        let permission = SessionStatusObservation(.waitingForInput, waitingReason: .permission)
        XCTAssertEqual(arbiter.accept(permission, from: .screen), permission)
        XCTAssertNil(
            arbiter.accept(SessionStatusObservation(.readyForReview), from: .screen),
            "a permission prompt repaint must not decay to Ready for Review while the turn is still active"
        )

        let stopped = SessionStatusObservation(.readyForReview, cause: "hook: Stop fullyIdle=true")
        XCTAssertEqual(arbiter.accept(stopped, from: .hook), stopped)
    }

    /// With no structured hook to defer to, every screen observation passes
    /// straight through.
    func testScreenObservationsPassThroughWithoutAHook() {
        var arbiter = SessionStatusObservationArbiter()
        for observation in [
            SessionStatusObservation(.working),
            SessionStatusObservation(.readyForReview),
            SessionStatusObservation(.waitingForInput, waitingReason: .permission),
        ] {
            XCTAssertEqual(arbiter.accept(observation, from: .screen), observation)
        }
    }

    /// A brand-new session (no persisted status) must not be promoted to
    /// Ready for Review by the screen heuristic before it has been seen doing
    /// anything — the agent's boot/welcome screen reads the same as a
    /// finished turn.
    func testScreenReadyForReviewIsHeldBackUntilTheSessionHasProgressed() {
        var arbiter = SessionStatusObservationArbiter(sessionHasProgressed: false)
        XCTAssertNil(arbiter.accept(SessionStatusObservation(.readyForReview), from: .screen))

        // Any working/waiting signal, from either source, opens the gate.
        XCTAssertEqual(
            arbiter.accept(SessionStatusObservation(.working), from: .screen),
            SessionStatusObservation(.working)
        )
        XCTAssertEqual(
            arbiter.accept(SessionStatusObservation(.readyForReview), from: .screen),
            SessionStatusObservation(.readyForReview)
        )
    }

    /// A hook `Stop` is authoritative: it establishes Ready for Review even
    /// on a session that has shown nothing else.
    func testHookReadyForReviewBypassesTheProgressGate() {
        var arbiter = SessionStatusObservationArbiter(sessionHasProgressed: false)
        let ready = SessionStatusObservation(.readyForReview, cause: "hook: Stop")
        XCTAssertEqual(arbiter.accept(ready, from: .hook), ready)
        // And a confirming screen reading now passes too.
        XCTAssertEqual(
            arbiter.accept(SessionStatusObservation(.readyForReview), from: .screen),
            SessionStatusObservation(.readyForReview)
        )
    }

    /// A restored session that was already Ready for Review keeps that status
    /// from the screen — it has a history, so the boot-screen guard does not
    /// apply.
    func testRestoredProgressedSessionAcceptsScreenReadyForReviewImmediately() {
        var arbiter = SessionStatusObservationArbiter(sessionHasProgressed: true)
        XCTAssertEqual(
            arbiter.accept(SessionStatusObservation(.readyForReview), from: .screen),
            SessionStatusObservation(.readyForReview)
        )
    }
}

final class HookConfigurationWriterTests: XCTestCase {
    private var workingDirectory: URL!
    private var supportDirectory: URL!

    override func setUp() {
        super.setUp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotilla-hookconfig-\(UUID().uuidString)")
        workingDirectory = root.appendingPathComponent("project")
        supportDirectory = root.appendingPathComponent("support")
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workingDirectory.deletingLastPathComponent())
        super.tearDown()
    }

    private var settingsFile: URL {
        workingDirectory.appendingPathComponent(".claude/settings.json")
    }

    private func runScript(
        at script: URL,
        arguments: [String] = [],
        stdin: String,
        eventFile: URL
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment[HookConfigurationWriter.eventFileEnvironmentKey] = eventFile.path
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
    func testConfigureHooksNeverTouchesSharedSettingsFile() {
        let writer = HookConfigurationWriter()
        let sessionID = UUID()
        let succeeded = writer.configureHooks(
            for: .claudeCode,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            supportDirectory: supportDirectory
        )

        XCTAssertTrue(succeeded)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: settingsFile.path),
            "hook wiring travels via launch arguments now, not a file every session in this project shares"
        )

        let eventFile = HookConfigurationWriter.eventFilePath(for: sessionID, supportDirectory: supportDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: eventFile.path))
    }

    func testConfigureHooksTruncatesStaleEventFileOnRelaunch() throws {
        let writer = HookConfigurationWriter()
        let sessionID = UUID()
        let eventFile = HookConfigurationWriter.eventFilePath(for: sessionID, supportDirectory: supportDirectory)
        try FileManager.default.createDirectory(at: eventFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("stale from a previous launch\n".utf8).write(to: eventFile)

        _ = writer.configureHooks(
            for: .claudeCode,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            supportDirectory: supportDirectory
        )

        let contents = try String(contentsOf: eventFile, encoding: .utf8)
        XCTAssertTrue(contents.isEmpty)
    }

    func testConfigureHooksCleansLegacyFixedPathClaudeHookGroups() throws {
        let writer = HookConfigurationWriter()
        let claudeDir = workingDirectory.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsFile = claudeDir.appendingPathComponent("settings.json", isDirectory: false)

        let legacyID = UUID()
        let legacyCommand = #"cat >> "/Users/test/Library/Application Support/Flotilla/hooks/\#(legacyID.uuidString).jsonl" && printf '\n' >> "/Users/test/Library/Application Support/Flotilla/hooks/\#(legacyID.uuidString).jsonl""#
        let modernCommand = #"event_file="${FLOTILLA_HOOK_EVENT_FILE:-}"; [ -n "$event_file" ] || exit 0; cat >> "$event_file" && printf '\n' >> "$event_file""#

        let initialSettings: [String: Any] = [
            "theme": "dark",
            "autoUpdaterStatus": "disabled",
            "hooks": [
                "Notification": [
                    ["hooks": [["type": "command", "command": legacyCommand]]],
                    ["hooks": [["type": "command", "command": modernCommand]]]
                ],
                "Stop": [
                    ["hooks": [["type": "command", "command": legacyCommand]]]
                ],
                "PostToolUse": [
                    ["hooks": [["type": "command", "command": "echo user-custom-hook"]]]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: initialSettings, options: [.prettyPrinted])
        try data.write(to: settingsFile)

        let sessionID = UUID()
        let succeeded = writer.configureHooks(
            for: .claudeCode,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            supportDirectory: supportDirectory
        )
        XCTAssertTrue(succeeded)

        // Verify the file was cleaned
        let updatedData = try Data(contentsOf: settingsFile)
        let updatedSettings = try XCTUnwrap(JSONSerialization.jsonObject(with: updatedData) as? [String: Any])

        XCTAssertEqual(updatedSettings["theme"] as? String, "dark")
        XCTAssertEqual(updatedSettings["autoUpdaterStatus"] as? String, "disabled")

        let updatedHooks = try XCTUnwrap(updatedSettings["hooks"] as? [String: Any])
        // Notification should have only the modern hook
        let notificationGroups = try XCTUnwrap(updatedHooks["Notification"] as? [[String: Any]])
        XCTAssertEqual(notificationGroups.count, 1)
        let notifCmd = ((notificationGroups.first?["hooks"] as? [[String: Any]])?.first)?["command"] as? String
        XCTAssertEqual(notifCmd, modernCommand)

        // Stop had only the legacy hook, so Stop should be removed
        XCTAssertNil(updatedHooks["Stop"])

        // PostToolUse had user custom hook, so it should remain
        let postToolGroups = try XCTUnwrap(updatedHooks["PostToolUse"] as? [[String: Any]])
        XCTAssertEqual(postToolGroups.count, 1)
        let postToolCmd = ((postToolGroups.first?["hooks"] as? [[String: Any]])?.first)?["command"] as? String
        XCTAssertEqual(postToolCmd, "echo user-custom-hook")
    }

    func testConfigureHooksRemovesEmptyHooksObjectWhenAllLegacy() throws {
        let writer = HookConfigurationWriter()
        let claudeDir = workingDirectory.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsFile = claudeDir.appendingPathComponent("settings.json", isDirectory: false)

        let legacyID = UUID()
        let legacyCommand = #"cat >> "/Users/test/Library/Application Support/Flotilla/hooks/\#(legacyID.uuidString).jsonl" && printf '\n' >> "/Users/test/Library/Application Support/Flotilla/hooks/\#(legacyID.uuidString).jsonl""#

        let initialSettings: [String: Any] = [
            "hooks": [
                "Notification": [
                    ["hooks": [["type": "command", "command": legacyCommand]]]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: initialSettings, options: [.prettyPrinted])
        try data.write(to: settingsFile)

        let sessionID = UUID()
        let succeeded = writer.configureHooks(
            for: .claudeCode,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            supportDirectory: supportDirectory
        )
        XCTAssertTrue(succeeded)

        let updatedData = try Data(contentsOf: settingsFile)
        let updatedSettings = try XCTUnwrap(JSONSerialization.jsonObject(with: updatedData) as? [String: Any])
        XCTAssertNil(updatedSettings["hooks"])
    }

    func testLaunchArgumentsCarryOnlyThisSessionsHookGroups() throws {
        let arguments = HookConfigurationWriter.launchArguments(
            for: .claudeCode,
            supportDirectory: supportDirectory
        )

        XCTAssertEqual(arguments.first, "--settings")
        let json = try XCTUnwrap(arguments.dropFirst().first)
        let settings = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let events = HookConfigurationWriter.claudeObservedEvents + ["PreToolUse", "PermissionRequest", "MessageDisplay"]
        XCTAssertEqual(Set(hooks.keys), Set(events))
        for event in events {
            let groups = try XCTUnwrap(hooks[event] as? [[String: Any]], "\(event) must be present")
            let handler = try XCTUnwrap((groups.first?["hooks"] as? [[String: Any]])?.first)
            let command = try XCTUnwrap(handler["command"] as? String)
            XCTAssertTrue(command.contains(HookConfigurationWriter.eventFileEnvironmentKey), event)
            // Only the decision hook may hold Claude up; recording runs in the background.
            XCTAssertEqual(handler["async"] as? Bool, event == "PermissionRequest" ? nil : true, event)
        }
        let preToolGroups = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(preToolGroups.first?["matcher"] as? String, "AskUserQuestion|ExitPlanMode")
        XCTAssertNil(hooks["SubagentStop"], "Claude's helpers fire SubagentStop after the turn's Stop")
    }

    /// Runs the generated commands the way Claude does — JSON on stdin, the
    /// event file in the environment — and checks where each line lands.
    func testClaudeHookCommandsRecordStatusAndDisplaySeparately() throws {
        let arguments = HookConfigurationWriter.launchArguments(for: .claudeCode, supportDirectory: supportDirectory)
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments[1].utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        func command(_ event: String) throws -> String {
            let groups = try XCTUnwrap(hooks[event] as? [[String: Any]])
            return try XCTUnwrap(((groups.first?["hooks"] as? [[String: Any]])?.first)?["command"] as? String)
        }
        let sessionID = UUID()
        let eventFile = HookConfigurationWriter.eventFilePath(for: sessionID, supportDirectory: supportDirectory)
        let displayFile = HookConfigurationWriter.displayFilePath(for: sessionID, supportDirectory: supportDirectory)
        try FileManager.default.createDirectory(at: eventFile.deletingLastPathComponent(), withIntermediateDirectories: true)

        func run(_ command: String, input: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = [HookConfigurationWriter.eventFileEnvironmentKey: eventFile.path]
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        try run(command("UserPromptSubmit"), input: #"{"hook_event_name":"UserPromptSubmit","prompt":"hi"}"#)
        try run(command("MessageDisplay"), input: #"{"hook_event_name":"MessageDisplay","message_id":"m","index":0,"final":false,"delta":"He"}"#)
        try run(command("Stop"), input: #"{"hook_event_name":"Stop"}"#)

        XCTAssertEqual(
            try String(contentsOf: eventFile, encoding: .utf8),
            #"{"hook_event_name":"UserPromptSubmit","prompt":"hi"}"# + "\n" + #"{"hook_event_name":"Stop"}"# + "\n"
        )
        XCTAssertEqual(
            try String(contentsOf: displayFile, encoding: .utf8),
            #"{"hook_event_name":"MessageDisplay","message_id":"m","index":0,"final":false,"delta":"He"}"# + "\n"
        )
    }

    func testClaudeSessionStartReportsTheConversationTheProcessIsIn() {
        let clear = #"{"hook_event_name":"SessionStart","session_id":"bb6257b4","source":"clear"}"#
        XCTAssertEqual(
            HookEventReceiver.sessionIdentityEvent(forLine: clear, agent: .claudeCode),
            HookSessionIdentityEvent(agent: .claudeCode, nativeSessionID: "bb6257b4", source: "clear")
        )
        XCTAssertNil(HookEventReceiver.sessionIdentityEvent(forLine: #"{"hook_event_name":"Stop","session_id":"x"}"#, agent: .claudeCode))
        XCTAssertNil(HookEventReceiver.sessionIdentityEvent(forLine: clear, agent: .codexCLI))
    }

    func testInterruptOnScreenEndsAHookHeldWorkingEpisode() {
        var arbiter = SessionStatusObservationArbiter(sessionHasProgressed: true)
        XCTAssertNotNil(arbiter.accept(SessionStatusObservation(.working, cause: "hook: UserPromptSubmit"), from: .hook))
        XCTAssertNil(
            arbiter.accept(SessionStatusObservation(.readyForReview, cause: "screen: composer"), from: .screen),
            "an ordinary composer redraw must not end the hook's working episode"
        )
        let interrupt = SessionStatusObservation(.readyForReview, cause: "screen: interrupt marker", endsTurn: true)
        XCTAssertEqual(arbiter.accept(interrupt, from: .screen), interrupt)
        XCTAssertNotNil(
            arbiter.accept(SessionStatusObservation(.readyForReview, cause: "screen: composer"), from: .screen),
            "after the interrupt nothing holds the session in Working"
        )
    }

    // OpenCode and Antigravity are hook-capable but their wiring travels through
    // configureHooks's stable project-plugin write, not launchArguments.
    func testLaunchArgumentsEmptyForPluginWiredProviders() {
        for agent in [AgentKind.openCode, .antigravity] {
            XCTAssertTrue(HookConfigurationWriter.supportsHooks(for: agent), "\(agent)")
            XCTAssertTrue(
                HookConfigurationWriter.launchArguments(for: agent, supportDirectory: supportDirectory).isEmpty,
                "\(agent)"
            )
        }
    }

    /// Never the real `~/.config/opencode/plugins`.
    private var openCodePluginsDirectory: URL {
        workingDirectory.deletingLastPathComponent().appendingPathComponent("opencode-plugins", isDirectory: true)
    }

    private var openCodeWriter: HookConfigurationWriter {
        HookConfigurationWriter(openCodeGlobalPluginsDirectory: openCodePluginsDirectory)
    }

    /// Never the real `~/.gemini/config/hooks.json`.
    private var antigravityHooksFile: URL {
        workingDirectory.deletingLastPathComponent().appendingPathComponent("gemini-config/hooks.json")
    }

    private var legacyProjectHooksFile: URL {
        workingDirectory.appendingPathComponent(".agents/hooks.json")
    }

    private var antigravityWriter: HookConfigurationWriter {
        HookConfigurationWriter(antigravityGlobalHooksFile: antigravityHooksFile)
    }

    private func configureAntigravity(sessionID: UUID = UUID()) -> Bool {
        antigravityWriter.configureHooks(
            for: .antigravity,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            supportDirectory: supportDirectory
        )
    }

    private func readAntigravityHooks() throws -> [String: Any] {
        let data = try Data(contentsOf: antigravityHooksFile)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["flotilla-status"] as? [String: Any])
    }

    private func antigravityCommand(_ event: String) throws -> String {
        let group = try readAntigravityHooks()
        let entries = try XCTUnwrap(group[event] as? [[String: Any]], "\(event) must be present")
        let handler = try XCTUnwrap((entries.first?["hooks"] as? [[String: Any]])?.first ?? entries.first)
        return try XCTUnwrap(handler["command"] as? String)
    }

    /// Runs a hooks-file command the way agy does: `sh -c`, JSON on stdin.
    private func runShellCommand(_ command: String, stdin: String, environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func testAntigravityInstallsOneUserLevelGroupAndNoProjectFile() throws {
        XCTAssertTrue(configureAntigravity())

        let scriptPath = supportDirectory.appendingPathComponent("hooks/flotilla-antigravity.sh")
        let attributes = try FileManager.default.attributesOfItem(atPath: scriptPath.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? Int)
        XCTAssertEqual(permissions & 0o111, 0o111, "the wrapper script must be executable")

        let group = try readAntigravityHooks()
        XCTAssertEqual(Set(group.keys), ["PreToolUse", "PostToolUse", "PreInvocation", "Stop"])
        for event in ["PreToolUse", "PostToolUse"] {
            let entries = try XCTUnwrap(group[event] as? [[String: Any]])
            XCTAssertEqual(entries.first?["matcher"] as? String, "*")
        }
        let stopEntries = try XCTUnwrap(group["Stop"] as? [[String: Any]])
        XCTAssertNil(stopEntries.first?["matcher"], "Stop doesn't support a matcher")
        for event in group.keys {
            let command = try antigravityCommand(event)
            XCTAssertTrue(command.hasSuffix(event), "the event name must be passed as the wrapper's argument")
            XCTAssertFalse(command.contains(supportDirectory.path), "the shared file must not name one install's support directory")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyProjectHooksFile.path), "nothing is written into the project")
    }

    func testAntigravityHookRecordsThroughTheSessionsEventFileAndDecidesNothing() throws {
        let sessionID = UUID()
        XCTAssertTrue(configureAntigravity(sessionID: sessionID))
        let eventFile = HookConfigurationWriter.eventFilePath(for: sessionID, supportDirectory: supportDirectory)

        let stdout = try runShellCommand(
            try antigravityCommand("PreToolUse"),
            stdin: #"{"toolCall":{"name":"ask_question"}}"#,
            environment: [HookConfigurationWriter.eventFileEnvironmentKey: eventFile.path]
        )

        XCTAssertEqual(stdout, "", "agy 1.3.0 treats a silent PreToolUse like no hook; an allow never skips its picker")
        XCTAssertEqual(
            try String(contentsOf: eventFile, encoding: .utf8),
            #"{"event":"PreToolUse","payload":{"toolCall":{"name":"ask_question"}}}"# + "\n"
        )
    }

    func testAntigravityHookIsInertOutsideFlotilla() throws {
        XCTAssertTrue(configureAntigravity())
        for event in ["PreToolUse", "PreInvocation", "Stop"] {
            XCTAssertEqual(try runShellCommand(try antigravityCommand(event), stdin: "{}", environment: [:]), "")
        }
    }

    /// A phone prompt sent mid-turn waits in the queue file until Antigravity's
    /// next `PreInvocation`, which must inject it exactly once.
    func testAntigravityPreInvocationInjectsQueuedPromptsOnce() throws {
        let sessionID = UUID()
        XCTAssertTrue(configureAntigravity(sessionID: sessionID))
        let eventFile = HookConfigurationWriter.eventFilePath(for: sessionID, supportDirectory: supportDirectory)
        let queued = #"{"injectSteps":[{"userMessage":"Also update the README"}]}"#
        try Data(queued.utf8).write(to: URL(fileURLWithPath: eventFile.path + ".queue"))
        let environment = [HookConfigurationWriter.eventFileEnvironmentKey: eventFile.path]

        let first = try runShellCommand(try antigravityCommand("PreInvocation"), stdin: "{}", environment: environment)
        let second = try runShellCommand(try antigravityCommand("PreInvocation"), stdin: "{}", environment: environment)

        XCTAssertEqual(first, queued)
        XCTAssertEqual(second, "", "a delivered prompt must not be injected again")
    }

    func testAntigravityRelaunchIsIdempotentNotAccumulating() throws {
        for _ in 0..<3 { XCTAssertTrue(configureAntigravity()) }

        let group = try readAntigravityHooks()
        for event in ["PreToolUse", "PostToolUse", "PreInvocation", "Stop"] {
            let entries = try XCTUnwrap(group[event] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1, "relaunching must replace, not accumulate, the entry for \(event)")
        }
    }

    func testAntigravityPreservesUnrelatedUserLevelHooks() throws {
        try FileManager.default.createDirectory(at: antigravityHooksFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing: [String: Any] = [
            "some-other-hook": ["Stop": [["type": "command", "command": "echo user-configured"]]]
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: antigravityHooksFile)

        XCTAssertTrue(configureAntigravity())

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: antigravityHooksFile)) as? [String: Any])
        XCTAssertNotNil(root["some-other-hook"], "an unrelated top-level hook entry must survive")
        XCTAssertNotNil(root["flotilla-status"])
    }

    func testAntigravityDoesNotReplaceMalformedUserConfig() throws {
        try FileManager.default.createDirectory(at: antigravityHooksFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let malformed = Data("user data that is not JSON".utf8)
        try malformed.write(to: antigravityHooksFile)

        XCTAssertFalse(configureAntigravity())
        XCTAssertEqual(try Data(contentsOf: antigravityHooksFile), malformed)
    }

    func testAntigravityRemovesTheGroupOlderReleasesWroteIntoTheProject() throws {
        try FileManager.default.createDirectory(at: legacyProjectHooksFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy: [String: Any] = [
            "flotilla-status": ["Stop": [["type": "command", "command": "'/old/support/hooks/flotilla-antigravity.sh' Stop"]]],
            "user-hook": ["Stop": [["type": "command", "command": "echo mine"]]]
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: legacyProjectHooksFile)

        XCTAssertTrue(configureAntigravity())
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: legacyProjectHooksFile)) as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["user-hook"])

        // A file that held only Flotilla's group goes away entirely.
        try JSONSerialization.data(withJSONObject: ["flotilla-status": [:] as [String: Any]]).write(to: legacyProjectHooksFile)
        XCTAssertTrue(configureAntigravity())
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyProjectHooksFile.path))

        // Unparseable project JSON is never rewritten.
        let malformed = Data("not json".utf8)
        try malformed.write(to: legacyProjectHooksFile)
        XCTAssertTrue(configureAntigravity(), "a project file Flotilla can't clean must not block the launch")
        XCTAssertEqual(try Data(contentsOf: legacyProjectHooksFile), malformed)
    }

    func testCodexWritesWrapperScriptAndBuildsInlineHookArguments() throws {
        let writer = HookConfigurationWriter()
        let sessionID = UUID()
        let succeeded = writer.configureHooks(
            for: .codexCLI,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            supportDirectory: supportDirectory
        )
        XCTAssertTrue(succeeded)

        let scriptPath = supportDirectory
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("flotilla-codex.sh", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptPath.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: scriptPath.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? Int)
        XCTAssertEqual(permissions & 0o111, 0o111, "the wrapper script must be executable")

        // Codex's script is observational: no output means the provider's
        // normal approval prompt remains in control.
        let scriptContents = try String(contentsOf: scriptPath, encoding: .utf8)
        XCTAssertFalse(scriptContents.contains("decision"))
        XCTAssertTrue(scriptContents.contains(HookConfigurationWriter.eventFileEnvironmentKey))

        let arguments = HookConfigurationWriter.launchArguments(
            for: .codexCLI,
            supportDirectory: supportDirectory
        )
        XCTAssertEqual(Array(arguments.prefix(2)), ["--config", "features.hooks=true"])
        for event in ["PreToolUse", "PermissionRequest", "PostToolUse", "Stop"] {
            let value = try XCTUnwrap(arguments.first { $0.hasPrefix("hooks.\(event)=") })
            XCTAssertTrue(value.contains(scriptPath.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workingDirectory.appendingPathComponent(".codex").path))
    }

    func testCodexWrapperCopiesSelfDescribingPayloadWithoutDecision() throws {
        let sessionID = UUID()
        XCTAssertTrue(HookConfigurationWriter().configureHooks(
            for: .codexCLI,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            supportDirectory: supportDirectory
        ))
        let script = supportDirectory.appendingPathComponent("hooks/flotilla-codex.sh")
        let eventFile = HookConfigurationWriter.eventFilePath(for: sessionID, supportDirectory: supportDirectory)
        let payload = #"{"hook_event_name":"PermissionRequest"}"#

        let stdout = try runScript(at: script, stdin: payload, eventFile: eventFile)

        XCTAssertTrue(stdout.isEmpty)
        XCTAssertEqual(try String(contentsOf: eventFile, encoding: .utf8), payload + "\n")
    }

    func testConcurrentAntigravityConfigurationRemainsValidAndBounded() async throws {
        let workingDirectory = try XCTUnwrap(workingDirectory)
        let supportDirectory = try XCTUnwrap(supportDirectory)
        let globalHooksFile = antigravityHooksFile
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<12 {
                group.addTask {
                    HookConfigurationWriter(antigravityGlobalHooksFile: globalHooksFile).configureHooks(
                        for: .antigravity,
                        sessionID: UUID(),
                        workingDirectory: workingDirectory,
                        supportDirectory: supportDirectory
                    )
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertTrue(results.allSatisfy { $0 })

        let hooks = try readAntigravityHooks()
        for event in ["PreToolUse", "PostToolUse", "PreInvocation", "Stop"] {
            XCTAssertEqual((hooks[event] as? [[String: Any]])?.count, 1)
        }
    }

    func testCodexNeverTouchesExistingProjectConfiguration() throws {
        let codexDir = workingDirectory.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let configFile = codexDir.appendingPathComponent("hooks.json")
        let existing = Data("user-owned, even if malformed".utf8)
        try existing.write(to: configFile)

        XCTAssertTrue(HookConfigurationWriter().configureHooks(
            for: .codexCLI,
            sessionID: UUID(),
            workingDirectory: workingDirectory,
            supportDirectory: supportDirectory
        ))

        XCTAssertEqual(try Data(contentsOf: configFile), existing)
    }
    func testOpenCodeRelaunchOverwritesRatherThanAccumulating() throws {
        let writer = openCodeWriter
        let sessionID = UUID()
        for _ in 0..<3 {
            _ = writer.configureHooks(
                for: .openCode,
                sessionID: sessionID,
                workingDirectory: workingDirectory,
                supportDirectory: supportDirectory
            )
        }

        let entries = try FileManager.default.contentsOfDirectory(atPath: openCodePluginsDirectory.path)
        XCTAssertEqual(entries.count, 1, "relaunching must overwrite, not accumulate, the stable plugin file")
    }

    func testOpenCodeTwoSessionsShareOneEnvironmentRoutedPlugin() throws {
        let writer = openCodeWriter
        _ = writer.configureHooks(
            for: .openCode,
            sessionID: UUID(),
            workingDirectory: workingDirectory,
            supportDirectory: supportDirectory
        )
        _ = writer.configureHooks(
            for: .openCode,
            sessionID: UUID(),
            workingDirectory: workingDirectory,
            supportDirectory: supportDirectory
        )

        let entries = try FileManager.default.contentsOfDirectory(atPath: openCodePluginsDirectory.path)
        XCTAssertEqual(entries, ["flotilla-status.js"], "one stable plugin routes each process to its own event file")
    }

    func testConcurrentOpenCodeConfigurationKeepsOneStablePlugin() async throws {
        let workingDirectory = try XCTUnwrap(workingDirectory)
        let supportDirectory = try XCTUnwrap(supportDirectory)
        let pluginsDirectory = openCodePluginsDirectory
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<12 {
                group.addTask {
                    HookConfigurationWriter(openCodeGlobalPluginsDirectory: pluginsDirectory).configureHooks(
                        for: .openCode,
                        sessionID: UUID(),
                        workingDirectory: workingDirectory,
                        supportDirectory: supportDirectory
                    )
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertTrue(results.allSatisfy { $0 })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pluginsDirectory.path), ["flotilla-status.js"])
    }

    func testOpenCodeRemovesLegacyPerSessionPlugins() throws {
        let pluginsDirectory = workingDirectory.appendingPathComponent(".opencode/plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        let legacy = pluginsDirectory.appendingPathComponent("flotilla-status-\(UUID().uuidString).js")
        let userPlugin = pluginsDirectory.appendingPathComponent("user-plugin.js")
        try Data().write(to: legacy)
        try Data().write(to: userPlugin)

        XCTAssertTrue(openCodeWriter.configureHooks(
            for: .openCode,
            sessionID: UUID(),
            workingDirectory: workingDirectory,
            supportDirectory: supportDirectory
        ))

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: userPlugin.path))
    }
}

final class SystemNotificationDispatcherRequestTests: XCTestCase {
    func testNotificationRequestsCarrySessionIdentity() {
        let sessionID = UUID()

        let waiting = SystemNotificationDispatcher.waitingForInputRequest(sessionTitle: "Fix the build", sessionID: sessionID)
        XCTAssertEqual(waiting.content.userInfo["sessionID"] as? String, sessionID.uuidString)
        XCTAssertEqual(waiting.content.threadIdentifier, sessionID.uuidString)
        XCTAssertEqual(waiting.content.categoryIdentifier, SystemNotificationDispatcher.waitingForInputCategoryIdentifier)
        XCTAssertEqual(waiting.content.title, "Needs Your Input")
        XCTAssertTrue(waiting.content.body.contains("Fix the build"))

        let finished = SystemNotificationDispatcher.finishedRequest(sessionTitle: "Fix the build", sessionID: sessionID)
        XCTAssertEqual(finished.content.userInfo["sessionID"] as? String, sessionID.uuidString)
        XCTAssertEqual(finished.content.threadIdentifier, sessionID.uuidString)
        XCTAssertTrue(finished.content.categoryIdentifier.isEmpty, "a finished session shouldn't offer the Reply action")
        XCTAssertEqual(finished.content.title, "Session Finished")
    }
}
