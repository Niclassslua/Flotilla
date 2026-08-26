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
        for status: SessionStatus in [.idle, .working, .finished, .crashed] {
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

    func testComposerWithNoInterruptHintMeansIdle() {
        XCTAssertEqual(heuristic.status(forScreen: idleScreen), .idle)
    }

    func testPermissionPromptMeansWaiting() {
        XCTAssertEqual(heuristic.status(forScreen: permissionScreen), .waitingForInput)
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
        XCTAssertEqual(heuristic.status(forScreen: screen), .idle)
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
        XCTAssertEqual(heuristic.status(forScreen: screen), .idle)
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
    ) async -> [SessionStatus] {
        let statuses = StatusBox()
        let collector = Task {
            for await status in monitor.statusStream { await statuses.append(status) }
        }
        monitor.start()
        try? await Task.sleep(for: settling)
        monitor.stop()
        collector.cancel()
        return await statuses.values
    }

    private actor StatusBox {
        private(set) var values: [SessionStatus] = []
        func append(_ status: SessionStatus) { values.append(status) }
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
        XCTAssertEqual(observed, [.idle])
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
        XCTAssertEqual(observed, [.working])
    }

    func testFollowsTheScreenFromWorkingToIdle() async {
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
        XCTAssertEqual(observed, [.working, .idle])
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
            for await status in monitor.statusStream {
                if gate.shouldNotify(for: status) {
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
    ) async -> [SessionStatus] {
        let statuses = StatusBox()
        let collector = Task {
            for await status in receiver.statusStream { await statuses.append(status) }
        }
        receiver.start()
        try? await Task.sleep(for: settling)
        receiver.stop()
        collector.cancel()
        return await statuses.values
    }

    private actor StatusBox {
        private(set) var values: [SessionStatus] = []
        func append(_ status: SessionStatus) { values.append(status) }
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

        let receiver = HookEventReceiver(filePath: file, pollInterval: .milliseconds(30))
        let statuses = StatusBox()
        let collector = Task {
            for await status in receiver.statusStream { await statuses.append(status) }
        }
        receiver.start()
        try await Task.sleep(for: .milliseconds(60))
        try append(#"{"hook_event_name":"PostToolUse","session_id":"abc"}"#, to: file)
        try await Task.sleep(for: .milliseconds(80))
        try append(#"{"hook_event_name":"Notification","session_id":"abc"}"#, to: file)
        try await Task.sleep(for: .milliseconds(80))
        try append(#"{"hook_event_name":"Stop","session_id":"abc"}"#, to: file)
        try await Task.sleep(for: .milliseconds(150))
        receiver.stop()
        collector.cancel()

        let observed = await statuses.values
        XCTAssertEqual(observed, [.working, .waitingForInput, .ready])
    }

    func testIgnoresUnknownEventNamesAndMalformedLines() async throws {
        let file = tempFile()
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }

        try append(#"{"hook_event_name":"SomeFutureEvent"}"#, to: file)
        try append("not json at all", to: file)
        try append(#"{"hook_event_name":"Stop"}"#, to: file)

        let receiver = HookEventReceiver(filePath: file, pollInterval: .milliseconds(30))
        let observed = await collect(from: receiver, settling: .milliseconds(200))

        XCTAssertEqual(observed, [.ready])
    }

    func testMissingFileYieldsNothingRatherThanCrashing() async {
        let receiver = HookEventReceiver(
            filePath: FileManager.default.temporaryDirectory.appendingPathComponent("flotilla-hook-tests-does-not-exist.jsonl"),
            pollInterval: .milliseconds(30)
        )
        let observed = await collect(from: receiver, settling: .milliseconds(150))
        XCTAssertTrue(observed.isEmpty)
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

    func testOnlyClaudeCodeSupportsHooks() {
        XCTAssertTrue(HookConfigurationWriter.supportsHooks(for: .claudeCode))
        XCTAssertFalse(HookConfigurationWriter.supportsHooks(for: .codexCLI))
        XCTAssertFalse(HookConfigurationWriter.supportsHooks(for: .openCode))
        XCTAssertFalse(HookConfigurationWriter.supportsHooks(for: .antigravity))
    }

    func testNonHookCapableAgentIsANoOp() {
        let writer = HookConfigurationWriter()
        let sessionID = UUID()
        let succeeded = writer.configureHooks(
            for: .codexCLI,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            supportDirectory: supportDirectory
        )
        XCTAssertFalse(succeeded)

        let eventFile = HookConfigurationWriter.eventFilePath(for: sessionID, supportDirectory: supportDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: eventFile.path))
        XCTAssertTrue(HookConfigurationWriter.launchArguments(
            for: .codexCLI,
            sessionID: sessionID,
            supportDirectory: supportDirectory
        ).isEmpty)
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
        let sessionID = UUID()
        let arguments = HookConfigurationWriter.launchArguments(
            for: .claudeCode,
            sessionID: sessionID,
            supportDirectory: supportDirectory
        )

        XCTAssertEqual(arguments.first, "--settings")
        let json = try XCTUnwrap(arguments.dropFirst().first)
        let settings = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let eventFile = HookConfigurationWriter.eventFilePath(for: sessionID, supportDirectory: supportDirectory)
        for event in ["Notification", "Stop", "PostToolUse"] {
            let groups = try XCTUnwrap(hooks[event] as? [[String: Any]], "\(event) must be present")
            let commands = try XCTUnwrap(groups.first?["hooks"] as? [[String: Any]])
            let command = try XCTUnwrap(commands.first?["command"] as? String)
            XCTAssertTrue(
                command.contains(eventFile.path),
                "\(event)'s command must point at this session's own event file"
            )
        }
    }

    func testLaunchArgumentsEmptyForNonHookCapableAgent() {
        XCTAssertTrue(HookConfigurationWriter.launchArguments(
            for: .antigravity,
            sessionID: UUID(),
            supportDirectory: supportDirectory
        ).isEmpty)
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
