import XCTest
import SessionKit
import ProcessKit
import HooksKit

final class SessionStatusHeuristicTests: XCTestCase {
    private let heuristic = SessionStatusHeuristic()

    func testDetectsCommonWaitingPhrases() {
        XCTAssertEqual(heuristic.detectStatus(in: "Do you want to proceed?"), .waitingForInput)
        XCTAssertEqual(heuristic.detectStatus(in: "Continue? (y/n)"), .waitingForInput)
        XCTAssertEqual(heuristic.detectStatus(in: "Permission required to write file"), .waitingForInput)
    }

    func testOrdinaryOutputDetectsNothing() {
        XCTAssertNil(heuristic.detectStatus(in: "Compiling module SessionKit..."))
        XCTAssertNil(heuristic.detectStatus(in: "Permission accepted; continuing"))
        XCTAssertNil(heuristic.detectStatus(in: ""))
    }
}

final class WaitingNotificationGateTests: XCTestCase {
    func testFiresOnlyOnTransitionIntoWaiting() {
        let gate = WaitingNotificationGate()
        XCTAssertTrue(gate.shouldNotify(for: .waitingForInput))
        XCTAssertFalse(gate.shouldNotify(for: .waitingForInput)) // still waiting, no repeat
        XCTAssertFalse(gate.shouldNotify(for: .working))
        XCTAssertTrue(gate.shouldNotify(for: .waitingForInput)) // waiting again after leaving
    }

    func testNeverFiresForNonWaitingStatuses() {
        let gate = WaitingNotificationGate()
        for status: SessionStatus in [.working, .readyForReview, .crashed] {
            XCTAssertFalse(gate.shouldNotify(for: status))
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

    func testInterruptHintMeansWorking() {
        XCTAssertEqual(heuristic.status(forScreen: workingScreen), .working)
    }

    func testComposerWithProviderFooterMeansReady() {
        XCTAssertEqual(heuristic.status(forScreen: idleScreen), .readyForReview)
    }

    func testPermissionPromptMeansWaiting() {
        XCTAssertEqual(
            heuristic.observation(forScreen: permissionScreen),
            SessionStatusObservation(.waitingForInput, waitingReason: .permission)
        )
    }

    /// A prompt outranks a spinner: some CLIs keep drawing the busy line
    /// underneath a question they are blocked on.
    func testPromptWinsOverSimultaneousInterruptHint() {
        let screen = """
        Do you want to allow this edit?
        ❯ 1. Yes
          2. No
        ✻ Waiting… (esc to interrupt)
        """
        XCTAssertEqual(heuristic.status(forScreen: screen), .waitingForInput)
    }

    /// The reason only the bottom of the screen is consulted: transcript
    /// text scrolled above the status area must not be mistaken for it.
    /// Markers still count while they sit within the inspected tail — this
    /// is a heuristic, and its protection is exactly the tail window.
    func testTranscriptScrolledAboveTheStatusAreaIsIgnored() {
        let transcript = (1...12)
            .map { "● Step \($0): the hint reads \"esc to interrupt\", then asks \"Do you want to proceed?\"" }
            .joined(separator: "\n")
        let screen = """
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
        XCTAssertEqual(heuristic.status(forScreen: screen), .readyForReview)
    }

    /// A numbered list the agent merely printed is not an open question —
    /// only a list with a live selection caret is.
    func testNumberedListWithoutSelectionCaretIsNotWaiting() {
        let screen = """
        Here are the next steps:
        1. Fix the beacon
        2. Fix the status word
        3. Ship it

        │ >                                        │
        """
        XCTAssertEqual(heuristic.status(forScreen: screen), .readyForReview)
    }

    func testLiveCodexComposerWithFooterMeansReady() {
        let screen = """
        • Plan implemented and the worktree remains clean.

        ────────────────────────────────────────────
        › Ask Codex to do anything

          gpt-5.6-sol medium · ~/Documents/Projects/SwiftUi/Flotilla
        """
        XCTAssertEqual(heuristic.status(forScreen: screen), .readyForReview)
    }

    func testLiveClaudeComposerWithSeveralFootersMeansReady() {
        let screen = """
        ⏺ The requested change is complete.
        ✻ Worked for 42s
        ─────────────────────────────── test-plan-mode ─
        ❯ clean up the worktree and branch
        ────────────────────────────────────────────────
        Est. usage: 1 Standard request
        ⏵⏵ auto mode on · 1 file changed
        """
        XCTAssertEqual(heuristic.status(forScreen: screen), .readyForReview)
    }

    func testCodexQuestionCarriesAnswerReason() {
        let screen = """
        Question 1/1 (1 unanswered)
        Which approach should I take?
        ❯ 1. Keep compatibility
          2. Simplify the API
        """
        XCTAssertEqual(
            heuristic.observation(forScreen: screen),
            SessionStatusObservation(.waitingForInput, waitingReason: .question)
        )
    }

    func testPlanApprovalCarriesPlanReadyReason() {
        let screen = """
        Proposed Plan
        1. Update the model
        2. Wire the UI
        Approve this plan?
        """
        XCTAssertEqual(
            heuristic.observation(forScreen: screen),
            SessionStatusObservation(.waitingForInput, waitingReason: .planApproval)
        )
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

    /// The property that fixes the reported bug: a screen that keeps saying
    /// the same thing produces exactly one status, no matter how many times
    /// it is redrawn or re-read.
    func testUnchangingScreenReportsStatusOnlyOnce() async {
        let reader = ScriptedScreenReader(["> ready", "> ready", "> ready", "> ready"])
        let monitor = SessionScreenMonitor(
            sessionID: UUID(),
            reader: reader,
            pollInterval: .milliseconds(30)
        )
        let observed = await collect(from: monitor)
        XCTAssertEqual(observed, [SessionStatusObservation(.readyForReview)])
        let readCount = await reader.readCount
        XCTAssertGreaterThan(readCount, 1, "the monitor should have polled repeatedly")
    }

    /// An animating spinner changes the screen on every frame but never
    /// changes what it means, so it must not produce a stream of updates.
    func testAnimatingSpinnerReportsWorkingOnlyOnce() async {
        let frames = ["✻", "✢", "·", "✳"].map { "\($0) Thinking… (esc to interrupt)" }
        let monitor = SessionScreenMonitor(
            sessionID: UUID(),
            reader: ScriptedScreenReader(frames),
            pollInterval: .milliseconds(30)
        )
        let observed = await collect(from: monitor)
        XCTAssertEqual(observed, [SessionStatusObservation(.working)])
    }

    func testFollowsTheScreenFromWorkingToReady() async {
        let reader = ScriptedScreenReader([
            "✻ Thinking… (esc to interrupt)",
            "✻ Thinking… (esc to interrupt)",
            "● Done.\n│ > │\n  ? for shortcuts",
        ])
        let monitor = SessionScreenMonitor(
            sessionID: UUID(),
            reader: reader,
            pollInterval: .milliseconds(30)
        )
        let observed = await collect(from: monitor)
        XCTAssertEqual(observed, [SessionStatusObservation(.working), SessionStatusObservation(.readyForReview)])
    }

    /// An unreadable screen is "no information" — the status must be left
    /// alone rather than decaying to idle on an absence.
    func testUnreadableScreenReportsNothing() async {
        let monitor = SessionScreenMonitor(
            sessionID: UUID(),
            reader: ScriptedScreenReader([nil]),
            pollInterval: .milliseconds(30)
        )
        let observed = await collect(from: monitor)
        XCTAssertTrue(observed.isEmpty)
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

    func testSupportsHooksMatchesImplementedProviders() {
        XCTAssertTrue(HookConfigurationWriter.supportsHooks(for: .claudeCode))
        XCTAssertTrue(HookConfigurationWriter.supportsHooks(for: .antigravity))
        XCTAssertTrue(HookConfigurationWriter.supportsHooks(for: .codexCLI))
        XCTAssertTrue(HookConfigurationWriter.supportsHooks(for: .openCode))
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
        for event in ["Notification", "PreToolUse", "PermissionRequest", "Stop", "PostToolUse"] {
            let groups = try XCTUnwrap(hooks[event] as? [[String: Any]], "\(event) must be present")
            let commands = try XCTUnwrap(groups.first?["hooks"] as? [[String: Any]])
            let command = try XCTUnwrap(commands.first?["command"] as? String)
            XCTAssertTrue(command.contains(HookConfigurationWriter.eventFileEnvironmentKey))
        }
        let preToolGroups = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(preToolGroups.first?["matcher"] as? String, "AskUserQuestion|ExitPlanMode")
    }

    // OpenCode is hook-capable but its wiring travels through
    // configureHooks's stable project-plugin write, not launchArguments.
    func testLaunchArgumentsEmptyForOpenCodeEvenThoughItSupportsHooks() {
        XCTAssertTrue(HookConfigurationWriter.supportsHooks(for: .openCode))
        XCTAssertTrue(HookConfigurationWriter.launchArguments(
            for: .openCode,
            supportDirectory: supportDirectory
        ).isEmpty)
    }

    func testLaunchArgumentsEnableStableCodexHooksFeature() {
        XCTAssertTrue(HookConfigurationWriter.supportsHooks(for: .codexCLI))
        XCTAssertEqual(
            Array(HookConfigurationWriter.launchArguments(
                for: .codexCLI,
                supportDirectory: supportDirectory
            ).prefix(2)),
            ["--config", "features.hooks=true"]
        )
    }

    // Antigravity is hook-capable but its wiring travels through
    // `configureHooks`'s shared-file write, not `launchArguments` — unlike
    // Claude Code, which has no per-invocation settings-override flag.
    func testLaunchArgumentsEmptyForAntigravityEvenThoughItSupportsHooks() {
        XCTAssertTrue(HookConfigurationWriter.supportsHooks(for: .antigravity))
        XCTAssertTrue(HookConfigurationWriter.launchArguments(
            for: .antigravity,
            supportDirectory: supportDirectory
        ).isEmpty)
    }

    private var antigravityHooksFile: URL {
        workingDirectory.appendingPathComponent(".agents/hooks.json")
    }

    private func readAntigravityHooks() throws -> [String: Any] {
        let data = try Data(contentsOf: antigravityHooksFile)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["flotilla-status"] as? [String: Any])
    }

    func testAntigravityWritesWrapperScriptAndHooksForAllThreeEvents() throws {
        let writer = HookConfigurationWriter()
        let sessionID = UUID()
        let succeeded = writer.configureHooks(
            for: .antigravity,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            supportDirectory: supportDirectory
        )
        XCTAssertTrue(succeeded)

        let scriptPath = supportDirectory
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("flotilla-antigravity.sh", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptPath.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: scriptPath.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? Int)
        XCTAssertEqual(permissions & 0o111, 0o111, "the wrapper script must be executable")

        let scriptContents = try String(contentsOf: scriptPath, encoding: .utf8)
        XCTAssertTrue(scriptContents.contains(#"$1"#), "event name must be read from the invocation argument, not stdin")
        XCTAssertTrue(scriptContents.contains(HookConfigurationWriter.eventFileEnvironmentKey))
        XCTAssertTrue(scriptContents.contains(#"{"decision":"allow"}"#), "PreToolUse's stdout must be a live decision or Antigravity may hang")

        let group = try readAntigravityHooks()
        for event in ["PreToolUse", "PostToolUse"] {
            let entries = try XCTUnwrap(group[event] as? [[String: Any]], "\(event) must be present")
            XCTAssertEqual(entries.first?["matcher"] as? String, "*")
            let commands = try XCTUnwrap(entries.first?["hooks"] as? [[String: Any]])
            let command = try XCTUnwrap(commands.first?["command"] as? String)
            XCTAssertTrue(command.contains(scriptPath.path))
            XCTAssertTrue(command.hasSuffix(event), "the event name must be passed as the script's argument")
        }
        let stopEntries = try XCTUnwrap(group["Stop"] as? [[String: Any]])
        XCTAssertNil(stopEntries.first?["matcher"], "Stop doesn't support a matcher")
        let stopCommand = try XCTUnwrap(stopEntries.first?["command"] as? String)
        XCTAssertTrue(stopCommand.hasSuffix("Stop"))
    }

    func testAntigravityWrapperRoutesThroughProcessEnvironment() throws {
        let sessionID = UUID()
        XCTAssertTrue(HookConfigurationWriter().configureHooks(
            for: .antigravity,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            supportDirectory: supportDirectory
        ))
        let script = supportDirectory.appendingPathComponent("hooks/flotilla-antigravity.sh")
        let eventFile = HookConfigurationWriter.eventFilePath(for: sessionID, supportDirectory: supportDirectory)

        let stdout = try runScript(
            at: script,
            arguments: ["PreToolUse"],
            stdin: #"{"toolCall":{"name":"ask_question"}}"#,
            eventFile: eventFile
        )

        XCTAssertEqual(stdout, "{\"decision\":\"allow\"}\n")
        let event = try String(contentsOf: eventFile, encoding: .utf8)
        XCTAssertTrue(event.contains(#"{"event":"PreToolUse","payload":{"toolCall":{"name":"ask_question"}}}"#))
    }

    func testAntigravityRelaunchIsIdempotentNotAccumulating() throws {
        let writer = HookConfigurationWriter()
        let sessionID = UUID()
        for _ in 0..<3 {
            _ = writer.configureHooks(
                for: .antigravity,
                sessionID: sessionID,
                workingDirectory: workingDirectory,
                supportDirectory: supportDirectory
            )
        }

        let group = try readAntigravityHooks()
        for event in ["PreToolUse", "PostToolUse", "Stop"] {
            let entries = try XCTUnwrap(group[event] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1, "relaunching the same session must replace, not accumulate, its own entry for \(event)")
        }
    }

    func testAntigravityPreservesUnrelatedExistingHooksConfig() throws {
        let agentsDir = workingDirectory.appendingPathComponent(".agents", isDirectory: true)
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let existing: [String: Any] = [
            "some-other-hook": [
                "Stop": [["type": "command", "command": "echo user-configured"]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: antigravityHooksFile)

        let writer = HookConfigurationWriter()
        _ = writer.configureHooks(
            for: .antigravity,
            sessionID: UUID(),
            workingDirectory: workingDirectory,
            supportDirectory: supportDirectory
        )

        let data = try Data(contentsOf: antigravityHooksFile)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(root["some-other-hook"], "an unrelated top-level hook entry must survive")
        XCTAssertNotNil(root["flotilla-status"])
    }

    func testAntigravityDoesNotReplaceMalformedUserConfig() throws {
        let agentsDir = workingDirectory.appendingPathComponent(".agents", isDirectory: true)
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let malformed = Data("user data that is not JSON".utf8)
        try malformed.write(to: antigravityHooksFile)

        let succeeded = HookConfigurationWriter().configureHooks(
            for: .antigravity,
            sessionID: UUID(),
            workingDirectory: workingDirectory,
            supportDirectory: supportDirectory
        )

        XCTAssertFalse(succeeded)
        XCTAssertEqual(try Data(contentsOf: antigravityHooksFile), malformed)
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
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<12 {
                group.addTask {
                    HookConfigurationWriter().configureHooks(
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

        let data = try Data(contentsOf: workingDirectory.appendingPathComponent(".agents/hooks.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(root["flotilla-status"] as? [String: Any])
        for event in ["PreToolUse", "PostToolUse", "Stop"] {
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

    func testOpenCodeWritesAPerSessionPluginFile() throws {
        let writer = HookConfigurationWriter()
        let sessionID = UUID()
        let succeeded = writer.configureHooks(
            for: .openCode,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            supportDirectory: supportDirectory
        )
        XCTAssertTrue(succeeded)

        let pluginPath = workingDirectory
            .appendingPathComponent(".opencode/plugins", isDirectory: true)
            .appendingPathComponent("flotilla-status.js", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pluginPath.path))

        let contents = try String(contentsOf: pluginPath, encoding: .utf8)
        XCTAssertTrue(contents.contains(HookConfigurationWriter.eventFileEnvironmentKey))
        XCTAssertTrue(contents.contains("tool.execute.after"))
        XCTAssertTrue(contents.contains("session.idle"))
        XCTAssertTrue(contents.contains("permission.asked"))
        XCTAssertTrue(contents.contains("question.asked"))
    }

    func testOpenCodeRelaunchOverwritesRatherThanAccumulating() throws {
        let writer = HookConfigurationWriter()
        let sessionID = UUID()
        for _ in 0..<3 {
            _ = writer.configureHooks(
                for: .openCode,
                sessionID: sessionID,
                workingDirectory: workingDirectory,
                supportDirectory: supportDirectory
            )
        }

        let pluginsDirectory = workingDirectory.appendingPathComponent(".opencode/plugins", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(atPath: pluginsDirectory.path)
        XCTAssertEqual(entries.count, 1, "relaunching must overwrite, not accumulate, the stable plugin file")
    }

    func testOpenCodeTwoSessionsShareOneEnvironmentRoutedPlugin() throws {
        let writer = HookConfigurationWriter()
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

        let pluginsDirectory = workingDirectory.appendingPathComponent(".opencode/plugins", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(atPath: pluginsDirectory.path)
        XCTAssertEqual(entries, ["flotilla-status.js"], "one stable plugin routes each process to its own event file")
    }

    func testConcurrentOpenCodeConfigurationKeepsOneStablePlugin() async throws {
        let workingDirectory = try XCTUnwrap(workingDirectory)
        let supportDirectory = try XCTUnwrap(supportDirectory)
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<12 {
                group.addTask {
                    HookConfigurationWriter().configureHooks(
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

        let pluginsDirectory = workingDirectory.appendingPathComponent(".opencode/plugins", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pluginsDirectory.path), ["flotilla-status.js"])
    }

    func testOpenCodeRemovesLegacyPerSessionPlugins() throws {
        let pluginsDirectory = workingDirectory.appendingPathComponent(".opencode/plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        let legacy = pluginsDirectory.appendingPathComponent("flotilla-status-\(UUID().uuidString).js")
        let userPlugin = pluginsDirectory.appendingPathComponent("user-plugin.js")
        try Data().write(to: legacy)
        try Data().write(to: userPlugin)

        XCTAssertTrue(HookConfigurationWriter().configureHooks(
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
    func testWaitingForInputRequestCarriesSessionIdentityAndCategory() {
        let sessionID = UUID()
        let request = SystemNotificationDispatcher.waitingForInputRequest(sessionTitle: "Fix the build", sessionID: sessionID)

        XCTAssertEqual(request.content.userInfo["sessionID"] as? String, sessionID.uuidString)
        XCTAssertEqual(request.content.threadIdentifier, sessionID.uuidString)
        XCTAssertEqual(request.content.categoryIdentifier, SystemNotificationDispatcher.waitingForInputCategoryIdentifier)
        XCTAssertEqual(request.content.title, "Needs Your Input")
        XCTAssertTrue(request.content.body.contains("Fix the build"))
    }

    func testFinishedRequestCarriesSessionIdentityWithoutReplyCategory() {
        let sessionID = UUID()
        let request = SystemNotificationDispatcher.finishedRequest(sessionTitle: "Fix the build", sessionID: sessionID)

        XCTAssertEqual(request.content.userInfo["sessionID"] as? String, sessionID.uuidString)
        XCTAssertEqual(request.content.threadIdentifier, sessionID.uuidString)
        XCTAssertTrue(request.content.categoryIdentifier.isEmpty, "a finished session shouldn't offer the Reply action")
        XCTAssertEqual(request.content.title, "Session Finished")
    }
}
