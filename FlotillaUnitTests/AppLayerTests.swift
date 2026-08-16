import XCTest
import SessionKit
import ProcessKit
import GitKit
import PersistenceKit
import SettingsKit
import TerminalKit
@testable import Flotilla

private struct FixedExecutableLocator: ExecutableLocating {
    let executable: URL?
    let tmuxExecutable: URL?

    init(executable: URL?, tmuxExecutable: URL? = nil) {
        self.executable = executable
        self.tmuxExecutable = tmuxExecutable
    }

    func locate(_ name: String) -> URL? {
        if name == "tmux" { return tmuxExecutable }
        return executable
    }
}

/// Deterministic server-health verdicts: the real probe shells out to the
/// machine's actual tmux server, whose state must never decide a test.
private final class StubTmuxServerProbe: TmuxServerProbing, @unchecked Sendable {
    var usable: Bool
    private(set) var probeCount = 0

    init(usable: Bool) {
        self.usable = usable
    }

    func serverIsUsable(tmuxExecutable: URL) -> Bool {
        probeCount += 1
        return usable
    }
}

@MainActor
final class TerminalPresentationTests: XCTestCase {
    func testSessionAndGridUseIndependentRenderersWithSharedOutput() async throws {
        let process = MockPTYProcess()
        try process.start(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 120, rows: 30)
        )
        let receivedOutput = expectation(description: "controller receives PTY output")
        let controller = TerminalController(
            sessionID: UUID(),
            process: process,
            accessibilityIdentifier: "TerminalView-Test",
            multilineNewlineSequence: Data([0x0A]),
            outputHandler: { _ in receivedOutput.fulfill() }
        )

        let sessionView = controller.terminalView(for: .session)
        let gridView = controller.terminalView(for: .grid)
        XCTAssertFalse(sessionView === gridView)

        process.simulateOutput("shared-renderer-output")
        await fulfillment(of: [receivedOutput], timeout: 2)

        let sessionText = String(decoding: sessionView.getTerminal().getBufferAsData(), as: UTF8.self)
        let gridText = String(decoding: gridView.getTerminal().getBufferAsData(), as: UTF8.self)
        XCTAssertTrue(sessionText.contains("shared-renderer-output"))
        XCTAssertTrue(gridText.contains("shared-renderer-output"))

        controller.sendMultilineNewline()
        XCTAssertEqual(process.sentInput.last, Data([0x0A]))
    }
}

private struct SelectiveExecutableLocator: ExecutableLocating {
    let availableNames: Set<String>

    func locate(_ name: String) -> URL? {
        availableNames.contains(name) ? URL(fileURLWithPath: "/usr/bin/env") : nil
    }
}

private final class RecordingProcessFactory: PTYProcessCreating, @unchecked Sendable {
    var shouldFailToStart = false
    private(set) var processes: [MockPTYProcess] = []

    func makeProcess() -> any PTYProcessProtocol {
        let process = MockPTYProcess()
        process.echoInputToOutput = true
        process.shouldFailToStart = shouldFailToStart
        processes.append(process)
        return process
    }
}

@MainActor
final class StartupCheckViewModelTests: XCTestCase {
    func testMissingOpenCodeIsDetectedButExcludedFromWarningItems() {
        let viewModel = StartupCheckViewModel(
            locator: SelectiveExecutableLocator(
                availableNames: ["git", "tmux", "gh", "claude", "codex"]
            )
        )

        XCTAssertEqual(viewModel.missingAgents, [.openCode])
        XCTAssertTrue(viewModel.warningItems.isEmpty)
    }

    func testOtherMissingAgentStillAppearsInWarningItems() {
        let viewModel = StartupCheckViewModel(
            locator: SelectiveExecutableLocator(
                availableNames: ["git", "tmux", "gh", "claude", "opencode"]
            )
        )

        XCTAssertEqual(viewModel.missingAgents, [.codexCLI])
        XCTAssertEqual(viewModel.warningItems, [AgentKind.codexCLI.displayName])
    }
}

@MainActor
final class SessionProcessManagerTests: XCTestCase {
    private func session(id: UUID = UUID()) -> Session {
        Session(
            id: id,
            title: "Repair build",
            goal: "Resolve every compiler error",
            agent: .codexCLI,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
    }

    func testStartUsesInjectedFactoryConfiguredArgumentsAndDeliversGoal() throws {
        let factory = RecordingProcessFactory()
        var settings = AppSettings()
        settings.agentArguments.codexCLIArguments = ["--profile", "careful"]
        let manager = SessionProcessManager(
            locator: FixedExecutableLocator(
                executable: URL(fileURLWithPath: "/usr/bin/env")
            ),
            processFactory: factory,
            settingsProvider: { settings },
            tmuxServerProbe: StubTmuxServerProbe(usable: false)
        )

        let model = session()
        let process = try manager.start(session: model)
        let mock = try XCTUnwrap(process as? MockPTYProcess)

        XCTAssertEqual(mock.startedExecutable?.path, "/usr/bin/env")
        XCTAssertEqual(mock.startedArguments, ["--profile", "careful"])
        XCTAssertEqual(mock.startedWorkingDirectory, model.workingDirectory)
        XCTAssertEqual(mock.sentInput, [Data("Resolve every compiler error\r".utf8)])
    }

    func testMissingAgentFailsTruthfullyWithoutCreatingFallbackProcess() {
        let factory = RecordingProcessFactory()
        let manager = SessionProcessManager(
            locator: FixedExecutableLocator(
                executable: nil,
                tmuxExecutable: URL(fileURLWithPath: "/usr/local/bin/tmux")
            ),
            processFactory: factory,
            tmuxServerProbe: StubTmuxServerProbe(usable: true)
        )

        XCTAssertThrowsError(try manager.start(session: session())) { error in
            guard case SessionProcessManager.LaunchError.executableNotFound(let agent, let binary, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(agent, .codexCLI)
            XCTAssertEqual(binary, "codex")
        }
        XCTAssertTrue(factory.processes.isEmpty, "missing agents must never silently fall back to a mock terminal")
    }

    func testFactoryStartFailurePropagatesAsAgentLaunchFailure() {
        let factory = RecordingProcessFactory()
        factory.shouldFailToStart = true
        let manager = SessionProcessManager(
            locator: FixedExecutableLocator(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                tmuxExecutable: URL(fileURLWithPath: "/usr/local/bin/tmux")
            ),
            processFactory: factory,
            tmuxServerProbe: StubTmuxServerProbe(usable: true)
        )

        XCTAssertThrowsError(try manager.start(session: session())) { error in
            guard case SessionProcessManager.LaunchError.failedToStart(let agent, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(agent, .codexCLI)
        }
    }

    func testUnexpectedCrashPublishesExitEventAndExplicitRestartUsesNewProcess() async throws {
        let factory = RecordingProcessFactory()
        let manager = SessionProcessManager(
            locator: FixedExecutableLocator(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                tmuxExecutable: URL(fileURLWithPath: "/usr/local/bin/tmux")
            ),
            processFactory: factory,
            tmuxServerProbe: StubTmuxServerProbe(usable: true)
        )
        let model = session()
        let event = expectation(description: "exit event")
        manager.eventHandler = { received in
            XCTAssertEqual(received, .terminated(sessionID: model.id, exitCode: 9))
            event.fulfill()
        }

        let first = try XCTUnwrap(try manager.start(session: model) as? MockPTYProcess)
        first.simulateCrash(code: 9)
        await fulfillment(of: [event], timeout: 1)

        let replacement = try XCTUnwrap(try manager.start(session: model, deliverGoal: false) as? MockPTYProcess)
        XCTAssertFalse(first === replacement)
        XCTAssertTrue(replacement.sentInput.isEmpty, "restart must not replay potentially destructive goals")
    }
}

@MainActor
final class AppStoreLifecycleTests: XCTestCase {
    private func manager(factory: RecordingProcessFactory) -> SessionProcessManager {
        SessionProcessManager(
            locator: FixedExecutableLocator(
                executable: URL(fileURLWithPath: "/usr/bin/env")
            ),
            processFactory: factory,
            tmuxServerProbe: StubTmuxServerProbe(usable: false)
        )
    }

    func testGeneralSessionStartsBeforeItIsPersistedAndSelected() async throws {
        let repository = try GRDBSessionRepository()
        let factory = RecordingProcessFactory()
        let store = AppStore(
            repository: repository,
            gitService: MockGitService(),
            processManager: manager(factory: factory),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") }
        )

        await store.createSession(
            title: "Investigate race",
            goal: "Find the race",
            agent: .claudeCode,
            projectFolder: nil,
            checkoutMode: .mainCheckout
        )

        XCTAssertNil(store.lastCreationError)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.selectedSessionID, store.sessions.first?.id)
        XCTAssertEqual(store.sessions.first?.status, .working)
        XCTAssertEqual(factory.processes.first?.sentInput, [Data("Find the race\r".utf8)])
    }

    func testWorktreeCreationFailureDoesNotCreateSession() async throws {
        let repository = try GRDBSessionRepository()
        let git = MockGitService()
        git.errorToThrow = GitServiceError.commandFailed(exitCode: 128, stderr: "not a repository")
        let factory = RecordingProcessFactory()
        let store = AppStore(
            repository: repository,
            gitService: git,
            processManager: manager(factory: factory),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") }
        )

        await store.createSession(
            title: "Broken worktree",
            goal: "Should fail",
            agent: .claudeCode,
            projectFolder: URL(fileURLWithPath: "/tmp/repo"),
            checkoutMode: .newWorktree
        )

        XCTAssertNotNil(store.lastCreationError)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(factory.processes.isEmpty)
    }

    func testFailedWorktreeCleanupKeepsSessionAndRestartsItsProcess() async throws {
        let repository = try GRDBSessionRepository()
        let project = Project(name: "Repo", rootPath: URL(fileURLWithPath: "/tmp/repo"))
        let session = Session(
            title: "Keep me",
            goal: "Work",
            agent: .codexCLI,
            projectID: project.id,
            workingDirectory: URL(fileURLWithPath: "/tmp/worktrees/keep-me"),
            worktree: WorktreeInfo(
                branchName: "flotilla/keep-me",
                worktreePath: URL(fileURLWithPath: "/tmp/worktrees/keep-me"),
                baseCheckoutPath: project.rootPath
            ),
            status: .working
        )
        try repository.save(project)
        try repository.save(session)

        let git = MockGitService()
        git.errorToThrow = GitServiceError.commandFailed(exitCode: 1, stderr: "locked")
        let factory = RecordingProcessFactory()
        let store = AppStore(
            repository: repository,
            gitService: git,
            processManager: manager(factory: factory),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") }
        )
        XCTAssertEqual(factory.processes.count, 1)

        await store.deleteSession(sessionID: session.id, deleteWorktree: true)

        XCTAssertEqual(store.sessions.map(\.id), [session.id])
        XCTAssertNotNil(store.lastOperationError)
        XCTAssertEqual(factory.processes.count, 2)
        XCTAssertTrue(factory.processes[1].isRunning)
        XCTAssertTrue(factory.processes[1].sentInput.isEmpty)
    }

    func testUnexpectedProcessCrashPersistsCrashedStateAndCanRestart() async throws {
        let repository = try GRDBSessionRepository()
        let session = Session(
            title: "Crash recovery",
            goal: "Work",
            agent: .codexCLI,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working
        )
        try repository.save(session)
        let factory = RecordingProcessFactory()
        let store = AppStore(
            repository: repository,
            gitService: MockGitService(),
            processManager: manager(factory: factory),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") }
        )

        factory.processes[0].simulateCrash(code: 7)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.sessions.first?.status, .crashed)
        XCTAssertEqual(try repository.loadAll().sessions.first?.status, .crashed)

        store.restartSession(sessionID: session.id)
        XCTAssertEqual(store.sessions.first?.status, .working)
        XCTAssertTrue(factory.processes[1].sentInput.isEmpty)
    }

    /// `store.appendTerminalOutput` now writes to an unobserved live buffer
    /// (see `AppStore.liveScrollback`) rather than the `sessions` array, so
    /// the retained bytes are read back via `store.scrollback(for:)`, not
    /// `store.sessions.first?.terminalScrollback`.
    func testScrollbackKeepsTheMostRecentBytesAtCap() async throws {
        let repository = try GRDBSessionRepository()
        let session = Session(
            title: "History",
            goal: "Work",
            agent: .codexCLI,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .finished
        )
        try repository.save(session)
        let store = AppStore(
            repository: repository,
            gitService: MockGitService(),
            processManager: manager(factory: RecordingProcessFactory()),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") }
        )
        let cap = 256 * 1_024
        // Tail is large enough to push the buffer past cap + trim slack
        // (64 KB) on its own, so the trim is guaranteed to run. Distinct
        // head/tail bytes let the assertion below tell a suffix-preserving
        // trim apart from one that merely gets the count right.
        let head = Data(repeating: 0x41, count: cap)
        let tail = Data(repeating: 0x42, count: 128 * 1_024)

        store.appendTerminalOutput(head, toSessionID: session.id)
        store.appendTerminalOutput(tail, toSessionID: session.id)
        try await Task.sleep(for: .milliseconds(500))

        let inMemory = store.scrollback(for: session.id)
        XCTAssertEqual(inMemory.count, cap)
        XCTAssertEqual(inMemory.suffix(tail.count), tail)
        XCTAssertTrue(inMemory.prefix(cap - tail.count).allSatisfy { $0 == 0x41 })

        // Debounced save fires 2 s after the last append.
        try await Task.sleep(for: .milliseconds(2200))
        let persisted = try repository.loadAll().sessions.first?.terminalScrollback
        XCTAssertEqual(persisted, inMemory)
    }

    /// Regression guard for the `@Observable` invalidation storm: terminal
    /// output used to mutate `sessions` (an observed property) on every PTY
    /// chunk, re-evaluating every view that reads `store.sessions` at PTY
    /// frequency instead of display frequency. It must not do that anymore.
    func testTerminalOutputDoesNotInvalidateObservedSessions() async throws {
        let repository = try GRDBSessionRepository()
        let session = Session(
            title: "Quiet",
            goal: "Work",
            agent: .codexCLI,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .finished
        )
        try repository.save(session)
        let store = AppStore(
            repository: repository,
            gitService: MockGitService(),
            processManager: manager(factory: RecordingProcessFactory()),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") }
        )

        // A single registration is enough: `onChange` fires at most once per
        // registration, and this test only needs to know whether the 20
        // appends below trigger it at all — not how many times.
        final class ChangeFlag: @unchecked Sendable {
            var changed = false
        }
        let changeFlag = ChangeFlag()
        withObservationTracking {
            _ = store.sessions
        } onChange: {
            changeFlag.changed = true
        }

        for _ in 0..<20 {
            store.appendTerminalOutput(Data(repeating: 0x43, count: 64 * 1_024), toSessionID: session.id)
        }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(changeFlag.changed)
        let scrollbackCount = store.scrollback(for: session.id).count
        XCTAssertGreaterThan(scrollbackCount, 0)
        XCTAssertLessThanOrEqual(scrollbackCount, 256 * 1_024 + 64 * 1_024)
    }

    /// Before the fix, once the buffer sat at cap a single 64 KB chunk ran
    /// `Data.removeFirst()` up to 65,536 times — each one a separate
    /// `@Observable` mutation. This bounds wall-clock time for a burst of
    /// appends at cap; it is a coarse regression guard rather than a
    /// benchmark, since the repo has no CI performance baseline.
    func testAppendingAtCapStaysWithinTimeBudget() async throws {
        let repository = try GRDBSessionRepository()
        let session = Session(
            title: "Busy",
            goal: "Work",
            agent: .codexCLI,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .finished
        )
        try repository.save(session)
        let store = AppStore(
            repository: repository,
            gitService: MockGitService(),
            processManager: manager(factory: RecordingProcessFactory()),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") }
        )
        let chunk = Data(repeating: 0x44, count: 64 * 1_024)
        store.appendTerminalOutput(Data(repeating: 0x41, count: 256 * 1_024), toSessionID: session.id)

        let start = Date()
        for _ in 0..<200 {
            store.appendTerminalOutput(chunk, toSessionID: session.id)
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.5)
    }
}
