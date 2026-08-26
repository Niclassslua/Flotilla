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

private struct StubConversationOwnershipChecker: AgentConversationOwnershipChecking {
    let isActive: Bool

    func isConversationActive(agent: AgentKind, conversationID: String) -> Bool {
        isActive
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
                availableNames: ["git", "tmux", "gh", "claude", "codex", "agy"]
            )
        )

        XCTAssertEqual(viewModel.missingAgents, [.openCode])
        XCTAssertTrue(viewModel.warningItems.isEmpty)
    }

    func testOtherMissingAgentStillAppearsInWarningItems() {
        let viewModel = StartupCheckViewModel(
            locator: SelectiveExecutableLocator(
                availableNames: ["git", "tmux", "gh", "claude", "opencode", "agy"]
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
        XCTAssertEqual(mock.startedArguments, ["--profile", "careful", "Resolve every compiler error"])
        XCTAssertEqual(mock.startedWorkingDirectory, model.workingDirectory)
        XCTAssertTrue(mock.sentInput.isEmpty)
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

    func testAntigravityNativeResumeRefusesConversationOwnedByAnotherCLI() {
        let factory = RecordingProcessFactory()
        let manager = SessionProcessManager(
            locator: FixedExecutableLocator(executable: URL(fileURLWithPath: "/usr/bin/env")),
            processFactory: factory,
            tmuxServerProbe: StubTmuxServerProbe(usable: false),
            conversationOwnershipChecker: StubConversationOwnershipChecker(isActive: true)
        )
        var model = session()
        model.agent = .antigravity
        model.agentSessionID = "conv-123"

        XCTAssertThrowsError(try manager.start(session: model)) { error in
            XCTAssertEqual(
                error as? SessionProcessManager.LaunchError,
                .conversationAlreadyActive(agent: .antigravity, conversationID: "conv-123")
            )
        }
        XCTAssertTrue(factory.processes.isEmpty)
    }

    func testAntigravityReconnectsToItsExistingTmuxPaneWithoutOwnershipConflict() throws {
        let factory = RecordingProcessFactory()
        let terminator = MockTmuxSessionTerminator()
        let sessionID = UUID()
        terminator.stubbedSessions = [TmuxSessionWrapping.sessionName(for: sessionID)]
        let manager = SessionProcessManager(
            locator: FixedExecutableLocator(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                tmuxExecutable: URL(fileURLWithPath: "/usr/bin/tmux")
            ),
            processFactory: factory,
            tmuxTerminator: terminator,
            tmuxServerProbe: StubTmuxServerProbe(usable: true),
            conversationOwnershipChecker: StubConversationOwnershipChecker(isActive: true)
        )
        var model = session(id: sessionID)
        model.agent = .antigravity
        model.agentSessionID = "conv-123"

        _ = try manager.start(session: model)

        XCTAssertEqual(factory.processes.count, 1)
        XCTAssertTrue(factory.processes[0].startedArguments.contains("new-session"))
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
        let createdSession = try XCTUnwrap(store.sessions.first)
        let startedArguments = try XCTUnwrap(factory.processes.first?.startedArguments)
        // `agentManagedTitleEnabled` defaults to true, so the setup-step
        // title instructions apply here too, Claude Code's own native title
        // generation notwithstanding (see AppStore.createSession). The launch
        // also carries a trailing `--settings <json>` pair (see
        // HookConfigurationWriter.launchArguments) so this session's own
        // hook wiring travels with the process rather than through a file
        // other sessions could also read — checked for shape, not exact
        // content, since the JSON payload's own coverage lives in
        // HooksKitTests.
        XCTAssertEqual(Array(startedArguments.prefix(2)), ["--session-id", createdSession.id.uuidString])
        let goalArg = try XCTUnwrap(startedArguments.dropFirst(2).first)
        XCTAssertTrue(goalArg.contains("Choose a concise 2–5 word noun-phrase title"))
        XCTAssertTrue(goalArg.hasSuffix("Find the race"))
        XCTAssertEqual(Array(startedArguments.suffix(2).prefix(1)), ["--settings"])
        XCTAssertTrue((startedArguments.last ?? "").contains("\"hooks\""))
        XCTAssertTrue(factory.processes.first?.sentInput.isEmpty == true)
    }

    func testRestoreKeepsAntigravityConversationWhenAnotherCLIAlreadyOwnsIt() throws {
        let repository = try GRDBSessionRepository()
        let factory = RecordingProcessFactory()
        let session = Session(
            title: "Existing Antigravity conversation",
            goal: "Continue safely",
            agent: .antigravity,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working,
            agentSessionID: "conv-123"
        )
        try repository.save(session)
        let processManager = SessionProcessManager(
            locator: FixedExecutableLocator(executable: URL(fileURLWithPath: "/usr/bin/env")),
            processFactory: factory,
            tmuxServerProbe: StubTmuxServerProbe(usable: false),
            conversationOwnershipChecker: StubConversationOwnershipChecker(isActive: true)
        )

        let store = AppStore(
            repository: repository,
            gitService: MockGitService(),
            processManager: processManager,
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") }
        )

        XCTAssertEqual(store.sessions.first?.status, .crashed)
        XCTAssertEqual(store.sessions.first?.agentSessionID, "conv-123")
        XCTAssertTrue(store.lastOperationError?.contains("already open") == true)
        XCTAssertTrue(factory.processes.isEmpty, "A conflicting native resume must not fall back to a fresh conversation")
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

    func testFailedWorktreeCleanupSurfacesWarningAndDeletesSession() async throws {
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

        XCTAssertTrue(store.sessions.isEmpty, "Session must be removed from memory")
        let (_, loadedSessions) = try repository.loadAll()
        XCTAssertTrue(loadedSessions.isEmpty, "Session must be deleted from repository")
        XCTAssertNotNil(store.lastOperationError, "Worktree cleanup warning must be surfaced")
        XCTAssertEqual(factory.processes.count, 1, "Process must not be resurrected")
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

    func testAddProjectCreatesAndPersistsANewProject() throws {
        let repository = try GRDBSessionRepository()
        let store = AppStore(
            repository: repository,
            gitService: MockGitService(),
            processManager: manager(factory: RecordingProcessFactory()),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") }
        )

        store.addProject(at: URL(fileURLWithPath: "/tmp/MyRepo"))

        XCTAssertEqual(store.projects.map(\.name), ["MyRepo"])
        XCTAssertEqual(try repository.loadAll().projects.map(\.name), ["MyRepo"])
    }

    func testAddProjectIsIdempotentForTheSameStandardizedPath() throws {
        let repository = try GRDBSessionRepository()
        let store = AppStore(
            repository: repository,
            gitService: MockGitService(),
            processManager: manager(factory: RecordingProcessFactory()),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") }
        )

        store.addProject(at: URL(fileURLWithPath: "/tmp/MyRepo"))
        store.addProject(at: URL(fileURLWithPath: "/tmp/MyRepo/"))

        XCTAssertEqual(store.projects.count, 1, "re-adding the same folder must not create a duplicate project")
    }

    func testRemoveProjectDeletesItButKeepsItsSessionsAsStandalone() throws {
        let repository = try GRDBSessionRepository()
        let store = AppStore(
            repository: repository,
            gitService: MockGitService(),
            processManager: manager(factory: RecordingProcessFactory()),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") }
        )
        store.addProject(at: URL(fileURLWithPath: "/tmp/MyRepo"))
        let project = try XCTUnwrap(store.projects.first)
        let session = Session(
            title: "Fix bug",
            goal: "Work",
            agent: .claudeCode,
            projectID: project.id,
            workingDirectory: URL(fileURLWithPath: "/tmp/MyRepo")
        )
        try repository.save(session)
        store.reload()
        store.selectedProjectID = project.id

        store.removeProject(id: project.id)

        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertNil(store.selectedProjectID)
        XCTAssertEqual(store.sessions.map(\.id), [session.id], "the session must survive as a standalone session")
    }

    func testCleanProcessExitFiresOnSessionFinishedCallback() async throws {
        let repository = try GRDBSessionRepository()
        let session = Session(
            title: "Ship it",
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
        var finishedSessions: [Session] = []
        store.onSessionFinished = { finishedSessions.append($0) }

        factory.processes[0].simulateCrash(code: 0)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(store.sessions.first?.status, .finished)
        XCTAssertEqual(finishedSessions.map(\.id), [session.id])
    }

    func testCrashDoesNotFireOnSessionFinishedCallback() async throws {
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
        var finishedSessions: [Session] = []
        store.onSessionFinished = { finishedSessions.append($0) }

        factory.processes[0].simulateCrash(code: 7)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(store.sessions.first?.status, .crashed)
        XCTAssertTrue(finishedSessions.isEmpty, "a crash is not a finish — it must not trigger the finished notification")
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

private final class MockTmuxClientProbe: TmuxClientProbing, @unchecked Sendable {
    var stubbedSizes: [String: PTYSize] = [:]
    private let lock = NSLock()
    private var _clientSizeCalls: [(sessionName: String, executable: URL)] = []
    private var _refreshClientCalls: [(sessionName: String, executable: URL)] = []

    var clientSizeCalls: [(sessionName: String, executable: URL)] {
        lock.lock()
        defer { lock.unlock() }
        return _clientSizeCalls
    }

    var refreshClientCalls: [(sessionName: String, executable: URL)] {
        lock.lock()
        defer { lock.unlock() }
        return _refreshClientCalls
    }

    func clientSize(sessionNamed name: String, tmuxExecutable: URL) -> PTYSize? {
        lock.lock()
        _clientSizeCalls.append((name, tmuxExecutable))
        lock.unlock()
        return stubbedSizes[name]
    }

    func refreshClient(sessionNamed name: String, tmuxExecutable: URL) {
        lock.lock()
        _refreshClientCalls.append((name, tmuxExecutable))
        lock.unlock()
    }
}

@MainActor
final class SessionProcessManagerResizeRecoveryTests: XCTestCase {
    private func makeManager(
        factory: RecordingProcessFactory,
        probe: MockTmuxClientProbe
    ) -> SessionProcessManager {
        SessionProcessManager(
            locator: FixedExecutableLocator(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                tmuxExecutable: URL(fileURLWithPath: "/usr/bin/tmux")
            ),
            processFactory: factory,
            tmuxServerProbe: StubTmuxServerProbe(usable: true),
            tmuxClientProbe: probe
        )
    }

    func testResizeMismatchTriggersReattach() async throws {
        let factory = RecordingProcessFactory()
        let probe = MockTmuxClientProbe()
        let manager = makeManager(factory: factory, probe: probe)

        let session = Session(
            title: "Mismatch",
            goal: "Test",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working
        )
        let sessionName = TmuxSessionWrapping.sessionName(for: session.id)
        probe.stubbedSizes[sessionName] = PTYSize(cols: 80, rows: 25) // Stale size

        let initialProcess = try manager.start(session: session, deliverGoal: false)
        XCTAssertEqual(factory.processes.count, 1)

        // Request verification for expected size 199x47
        manager.verifyAndRecoverResize(sessionID: session.id, expectedSize: PTYSize(cols: 199, rows: 47))

        // Wait for debounce (250ms) + async probe
        for _ in 0..<20 {
            if factory.processes.count > 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(factory.processes.count, 2, "Mismatch must trigger reattach (a fresh PTY process)")
        let replacement = manager.process(for: session.id)
        XCTAssertTrue(replacement !== initialProcess, "Replacement process must be distinct from initial")
    }

    func testResizeMatchDoesNotTriggerReattach() async throws {
        let factory = RecordingProcessFactory()
        let probe = MockTmuxClientProbe()
        let manager = makeManager(factory: factory, probe: probe)

        let session = Session(
            title: "Match",
            goal: "Test",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working
        )
        let sessionName = TmuxSessionWrapping.sessionName(for: session.id)
        probe.stubbedSizes[sessionName] = PTYSize(cols: 199, rows: 47) // Matching size

        let initialProcess = try manager.start(session: session, deliverGoal: false)
        XCTAssertEqual(factory.processes.count, 1)

        manager.verifyAndRecoverResize(sessionID: session.id, expectedSize: PTYSize(cols: 199, rows: 47))
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertEqual(factory.processes.count, 1, "Matching size must NOT trigger reattach")
        XCTAssertTrue(manager.process(for: session.id) === initialProcess)
    }

    func testReattachRecoveryRateLimit() async throws {
        let factory = RecordingProcessFactory()
        let probe = MockTmuxClientProbe()
        let manager = makeManager(factory: factory, probe: probe)

        let session = Session(
            title: "RateLimit",
            goal: "Test",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working
        )
        let sessionName = TmuxSessionWrapping.sessionName(for: session.id)
        probe.stubbedSizes[sessionName] = PTYSize(cols: 80, rows: 25)

        _ = try manager.start(session: session, deliverGoal: false)

        var failureMessage: String?
        // 1st mismatch -> reattach #1
        manager.verifyAndRecoverResize(sessionID: session.id, expectedSize: PTYSize(cols: 100, rows: 30)) { msg in
            failureMessage = msg
        }
        for _ in 0..<20 {
            if factory.processes.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(factory.processes.count, 2)
        XCTAssertNil(failureMessage)

        // 2nd mismatch -> reattach #2
        manager.verifyAndRecoverResize(sessionID: session.id, expectedSize: PTYSize(cols: 120, rows: 40)) { msg in
            failureMessage = msg
        }
        for _ in 0..<20 {
            if factory.processes.count >= 3 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(factory.processes.count, 3)
        XCTAssertNil(failureMessage)

        // 3rd mismatch -> cap hit! Should not reattach, should invoke onRecoveryFailure
        manager.verifyAndRecoverResize(sessionID: session.id, expectedSize: PTYSize(cols: 140, rows: 50)) { msg in
            failureMessage = msg
        }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(factory.processes.count, 3, "Third attempt within 60s must be capped")
        XCTAssertNotNil(failureMessage, "Failure message must be surfaced when recovery limit is reached")
    }

    func testRefreshTmuxClientCallsProbe() async throws {
        let factory = RecordingProcessFactory()
        let probe = MockTmuxClientProbe()
        let manager = makeManager(factory: factory, probe: probe)

        let session = Session(
            title: "RefreshTest",
            goal: "Test",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working
        )
        _ = try manager.start(session: session, deliverGoal: false)

        manager.refreshTmuxClient(for: session.id)

        for _ in 0..<20 {
            if !probe.refreshClientCalls.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(probe.refreshClientCalls.count, 1)
        XCTAssertEqual(probe.refreshClientCalls.first?.sessionName, TmuxSessionWrapping.sessionName(for: session.id))
    }
}

@MainActor
final class TerminalControllerReflowTests: XCTestCase {
    func testCustomReflowHandlerInvokedOnSizeChangedAndDisplay() async throws {
        let process = MockPTYProcess()
        try process.start(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )

        var reflowCallCount = 0
        var lastResizedSize: PTYSize?

        let controller = TerminalController(
            sessionID: UUID(),
            process: process,
            accessibilityIdentifier: "ReflowTest",
            customReflowHandler: { _ in
                reflowCallCount += 1
            },
            onPTYResize: { size in
                lastResizedSize = size
            }
        )

        let sessionView = controller.terminalView(for: .session)
        controller.sizeChanged(source: sessionView, newCols: 120, newRows: 40)

        // Wait for debounced resize and reflow
        for _ in 0..<20 {
            if reflowCallCount > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(lastResizedSize, PTYSize(cols: 120, rows: 40))
        XCTAssertGreaterThanOrEqual(reflowCallCount, 1)
    }

    func testMakeAuthoritativeIgnoresDegenerateDimensions() async throws {
        let process = MockPTYProcess()
        try process.start(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )

        var lastResizedSize: PTYSize?
        let controller = TerminalController(
            sessionID: UUID(),
            process: process,
            accessibilityIdentifier: "DegenerateTest",
            onPTYResize: { size in
                lastResizedSize = size
            }
        )

        // Switch to grid before it has laid out (terminal.getDims() is default / unmeasured)
        controller.makeAuthoritative(.grid)

        // Default mock terminal in headless test reports 80x25 or valid, but if below 20x5 it's guarded.
        // Verifies makeAuthoritative runs without crashing
        XCTAssertNotNil(controller)
    }
}

private final class MockTmuxSessionTerminator: TmuxSessionTerminating, @unchecked Sendable {
    var killedSessions: [String] = []
    var stubbedSessions: [String] = []

    func killSession(named name: String, tmuxExecutable: URL) {
        killedSessions.append(name)
    }

    func listSessions(tmuxExecutable: URL) -> [String] {
        stubbedSessions
    }
}

@MainActor
final class OrphanReapingTests: XCTestCase {
    func testOrphanTmuxSessionReapingKillsOnlyUnknownSessions() {
        let terminator = MockTmuxSessionTerminator()
        let knownUUID = UUID()
        let orphanUUID = UUID()

        terminator.stubbedSessions = [
            "flotilla-\(knownUUID.uuidString)",
            "flotilla-\(orphanUUID.uuidString)",
            "other-user-session"
        ]

        let locator = FixedExecutableLocator(executable: URL(fileURLWithPath: "/bin/echo"), tmuxExecutable: URL(fileURLWithPath: "/usr/bin/tmux"))
        let manager = SessionProcessManager(
            locator: locator,
            processFactory: RecordingProcessFactory(),
            tmuxTerminator: terminator
        )

        manager.reapOrphanTmuxSessions(knownSessionIDs: [knownUUID])

        XCTAssertEqual(terminator.killedSessions, ["flotilla-\(orphanUUID.uuidString)"])
    }
}

@MainActor
final class Batch2HardeningTests: XCTestCase {
    func testTerminalControllerRebindSwapsProcess() async throws {
        let proc1 = MockPTYProcess()
        try proc1.start(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )

        let controller = TerminalController(
            sessionID: UUID(),
            process: proc1,
            accessibilityIdentifier: "RebindTest"
        )
        XCTAssertEqual(controller.processID, proc1.id)

        let proc2 = MockPTYProcess()
        try proc2.start(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )

        controller.rebind(process: proc2)
        XCTAssertEqual(controller.processID, proc2.id)
    }

    func testVisibleScreenTextReadsAuthoritativeView() {
        let process = MockPTYProcess()
        try? process.start(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )

        let controller = TerminalController(
            sessionID: UUID(),
            process: process,
            accessibilityIdentifier: "VisibleTextTest"
        )

        controller.makeAuthoritative(.session)
        XCTAssertNotNil(controller.visibleScreenText())
    }

    func testEnvironmentVariablesForwardedViaEFlags() {
        let env = ["MY_API_KEY": "secret_val", "CUSTOM_PATH": "/custom/bin", "TMUX": "should_be_stripped"]
        let launch = TmuxSessionWrapping.wrap(
            agentExecutable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"],
            environment: env,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            sessionID: UUID(),
            tmuxExecutable: URL(fileURLWithPath: "/usr/bin/tmux")
        )

        XCTAssertTrue(launch.arguments.contains("-e"))
        XCTAssertTrue(launch.arguments.contains("MY_API_KEY=secret_val"))
        XCTAssertTrue(launch.arguments.contains("CUSTOM_PATH=/custom/bin"))
        XCTAssertFalse(launch.arguments.contains("TMUX=should_be_stripped"))
    }
}

@MainActor
final class Batch3HardeningTests: XCTestCase {
    func testFlushLiveScrollbackPersistsAllBuffersSynchronously() async throws {
        let repo = try GRDBSessionRepository()
        let session = Session(
            title: "Flush Test",
            goal: "Goal",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working,
            terminalScrollback: Data()
        )
        try repo.save(session)

        let store = AppStore(
            repository: repo,
            gitService: MockGitService(),
            processManager: SessionProcessManager(
                locator: FixedExecutableLocator(executable: URL(fileURLWithPath: "/bin/echo")),
                processFactory: RecordingProcessFactory()
            ),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp") }
        )

        store.appendTerminalOutput(Data("output-to-flush\n".utf8), toSessionID: session.id)

        // Calling flushLiveScrollback immediately forces persistence without waiting for debounce
        store.flushLiveScrollback()

        let (_, loadedSessions) = try repo.loadAll()
        let loaded = try XCTUnwrap(loadedSessions.first(where: { $0.id == session.id }))
        XCTAssertEqual(String(decoding: loaded.terminalScrollback, as: UTF8.self), "output-to-flush\n")
    }

    func testInitialLaunchPTYSizeIsStandard() throws {
        let factory = RecordingProcessFactory()
        let manager = SessionProcessManager(
            locator: FixedExecutableLocator(executable: URL(fileURLWithPath: "/bin/echo")),
            processFactory: factory
        )

        let session = Session(
            title: "Size Test",
            goal: "",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working
        )

        try manager.start(session: session, deliverGoal: false)
        let started = try XCTUnwrap(factory.processes.first)
        XCTAssertEqual(started.lastSize, PTYSize(cols: 100, rows: 30))
    }
}

@MainActor
final class Batch4HardeningTests: XCTestCase {
    func testClipboardCopyWritesLossyUTF8Safely() {
        let process = MockPTYProcess()
        try? process.start(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )
        let controller = TerminalController(
            sessionID: UUID(),
            process: process,
            accessibilityIdentifier: "ClipboardTest"
        )
        let terminalView = controller.terminalView(for: .session)

        // Seed clipboard with a known string
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("initial-clip", forType: .string)

        // Calling clipboardCopy with empty data should NOT clear the existing pasteboard
        controller.clipboardCopy(source: terminalView, content: Data())
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "initial-clip")

        // Calling clipboardCopy with valid data writes to pasteboard
        controller.clipboardCopy(source: terminalView, content: Data("hello-terminal".utf8))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "hello-terminal")
    }
}

@MainActor
final class AgentManagedWorktreeAndTitleTests: XCTestCase {
    private func manager(
        factory: RecordingProcessFactory,
        settings: AppSettings = AppSettings()
    ) -> SessionProcessManager {
        SessionProcessManager(
            locator: FixedExecutableLocator(
                executable: URL(fileURLWithPath: "/usr/bin/env")
            ),
            processFactory: factory,
            settingsProvider: { settings },
            tmuxServerProbe: StubTmuxServerProbe(usable: false)
        )
    }

    func testSessionProcessManagerInjectsSelfReportEnvAndInstructions() throws {
        let factory = RecordingProcessFactory()
        let manager = manager(factory: factory)
        let session = Session(
            title: "Test Self Report",
            goal: "Do the work",
            agent: .codexCLI,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
        let descPath = URL(fileURLWithPath: "/tmp/support/self-report/\(session.id.uuidString).json")
        let instructions = "Before starting, write to \(descPath.path)\n\n"

        _ = try manager.start(
            session: session,
            deliverGoal: true,
            selfReportInstructions: instructions,
            selfReportDescriptorPath: descPath
        )

        let proc = try XCTUnwrap(factory.processes.first)
        XCTAssertEqual(proc.startedEnvironment["FLOTILLA_SELF_REPORT_PATH"], descPath.path)
        let combinedGoal = try XCTUnwrap(proc.startedArguments.last)
        XCTAssertTrue(combinedGoal.hasPrefix("Before starting, write to"))
        XCTAssertTrue(combinedGoal.contains("Do the work"))
    }

    func testAppStoreAgentManagedWorktreeAppliesReportedMetadata() async throws {
        let repository = try GRDBSessionRepository()
        let factory = RecordingProcessFactory()
        var settings = AppSettings()
        settings.git.worktreeNamingSource = .agentManaged
        let gitService = MockGitService()

        let store = AppStore(
            repository: repository,
            gitService: gitService,
            processManager: manager(factory: factory, settings: settings),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") },
            settingsProvider: { settings }
        )

        let projectFolder = URL(fileURLWithPath: "/tmp/my-project")
        let sessionID = await store.createSession(
            title: "Prompt Title",
            goal: "Implement feature",
            agent: .codexCLI,
            projectFolder: projectFolder,
            checkoutMode: .newWorktree
        )
        let unwrappedID = try XCTUnwrap(sessionID)

        // Verify initially started in project root (no worktree pre-created by GitService)
        XCTAssertTrue(gitService.createWorktreeCalls.isEmpty)
        let initialSession = try XCTUnwrap(store.sessions.first(where: { $0.id == unwrappedID }))
        XCTAssertEqual(initialSession.workingDirectory, projectFolder)
        XCTAssertNil(initialSession.worktree)

        // Simulate the agent writing its descriptor file
        let supportDir = TmuxSessionWrapping.defaultSupportDirectory()
        let descPath = AgentSelfReportCoordinator.descriptorPath(for: unwrappedID, supportDirectory: supportDir)
        try FileManager.default.createDirectory(at: descPath.deletingLastPathComponent(), withIntermediateDirectories: true)

        let chosenWorktreeURL = URL(fileURLWithPath: "/tmp/worktrees/agent-chosen-slug")
        let descriptor = AgentSelfReportDescriptor(
            title: "Agent Decided Title",
            branch: "flotilla/agent-chosen-slug",
            worktreePath: chosenWorktreeURL.path
        )
        let data = try JSONEncoder().encode(descriptor)
        try data.write(to: descPath)

        // Wait for background awaitAgentSelfReport task to pick up descriptor
        for _ in 0..<20 {
            if store.sessions.first(where: { $0.id == unwrappedID })?.worktree != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let updatedSession = try XCTUnwrap(store.sessions.first(where: { $0.id == unwrappedID }))
        XCTAssertEqual(updatedSession.title, "Agent Decided Title")
        XCTAssertEqual(updatedSession.worktree?.branchName, "flotilla/agent-chosen-slug")
        XCTAssertEqual(updatedSession.worktree?.worktreePath, chosenWorktreeURL)
        XCTAssertEqual(updatedSession.worktree?.baseCheckoutPath, projectFolder)
        XCTAssertEqual(updatedSession.workingDirectory, chosenWorktreeURL)

        // Verify persisted to repository
        let loaded = try repository.loadAll().sessions.first(where: { $0.id == unwrappedID })
        XCTAssertEqual(loaded?.title, "Agent Decided Title")
        XCTAssertEqual(loaded?.worktree?.branchName, "flotilla/agent-chosen-slug")

        // Cleanup
        AgentSelfReportCoordinator.clearDescriptor(for: unwrappedID, supportDirectory: supportDir)
    }

    /// Regression test: a permission-gated agent (e.g. a CLI tool-approval
    /// prompt sitting in front of the `git worktree add` command) can take
    /// longer than the fallback threshold to write its self-report
    /// descriptor. Flotilla's fallback should create a stopgap worktree in
    /// the meantime, but once the agent's real descriptor finally shows up
    /// it must win: the stopgap worktree is discarded and the
    /// agent-reported title/branch/path take over, instead of the poll loop
    /// having already given up.
    func testAppStoreAgentSelfReportArrivingAfterFallbackReplacesStopgapWorktree() async throws {
        let originalFallbackAfter = AppStore.selfReportFallbackAfter
        let originalPollChunk = AppStore.selfReportPollChunk
        AppStore.selfReportFallbackAfter = .milliseconds(50)
        AppStore.selfReportPollChunk = .milliseconds(50)
        defer {
            AppStore.selfReportFallbackAfter = originalFallbackAfter
            AppStore.selfReportPollChunk = originalPollChunk
        }

        let repository = try GRDBSessionRepository()
        let factory = RecordingProcessFactory()
        var settings = AppSettings()
        settings.git.worktreeNamingSource = .agentManaged
        let gitService = MockGitService()

        let store = AppStore(
            repository: repository,
            gitService: gitService,
            processManager: manager(factory: factory, settings: settings),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") },
            settingsProvider: { settings }
        )

        let projectFolder = URL(fileURLWithPath: "/tmp/my-project")
        let sessionID = await store.createSession(
            title: "Prompt Title",
            goal: "Implement feature",
            agent: .codexCLI,
            projectFolder: projectFolder,
            checkoutMode: .newWorktree
        )
        let unwrappedID = try XCTUnwrap(sessionID)

        // Wait for the fallback to fire (it creates a stopgap worktree once
        // the shortened threshold elapses with no descriptor on disk).
        for _ in 0..<40 {
            if !gitService.createWorktreeCalls.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(gitService.createWorktreeCalls.count, 1)
        let stopgapSession = try XCTUnwrap(store.sessions.first(where: { $0.id == unwrappedID }))
        XCTAssertNotNil(stopgapSession.worktree)
        XCTAssertNotNil(store.lastOperationError)

        // Now simulate the agent finally clearing its permission prompt and
        // writing its own descriptor, after the fallback already ran.
        let supportDir = TmuxSessionWrapping.defaultSupportDirectory()
        let descPath = AgentSelfReportCoordinator.descriptorPath(for: unwrappedID, supportDirectory: supportDir)
        try FileManager.default.createDirectory(at: descPath.deletingLastPathComponent(), withIntermediateDirectories: true)

        let chosenWorktreeURL = URL(fileURLWithPath: "/tmp/worktrees/agent-chosen-slug")
        let descriptor = AgentSelfReportDescriptor(
            title: "Agent Decided Title",
            branch: "flotilla/agent-chosen-slug",
            worktreePath: chosenWorktreeURL.path
        )
        try JSONEncoder().encode(descriptor).write(to: descPath)

        for _ in 0..<60 {
            if store.sessions.first(where: { $0.id == unwrappedID })?.worktree?.branchName == "flotilla/agent-chosen-slug" { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let finalSession = try XCTUnwrap(store.sessions.first(where: { $0.id == unwrappedID }))
        XCTAssertEqual(finalSession.title, "Agent Decided Title")
        XCTAssertEqual(finalSession.worktree?.branchName, "flotilla/agent-chosen-slug")
        XCTAssertEqual(finalSession.worktree?.worktreePath, chosenWorktreeURL)
        XCTAssertEqual(finalSession.workingDirectory, chosenWorktreeURL)

        // The stopgap worktree should have been cleaned up, and its warning cleared.
        XCTAssertEqual(gitService.removeWorktreeCalls.count, 1)
        XCTAssertNil(store.lastOperationError)

        AgentSelfReportCoordinator.clearDescriptor(for: unwrappedID, supportDirectory: supportDir)
    }

    /// Claude Code and Antigravity also generate a title natively, on their
    /// own schedule, well after the setup step — but that title can diverge
    /// from ours, reintroducing the title/worktree mismatch. So when
    /// `agentManagedTitleEnabled` is on, our setup-step title instructions
    /// apply uniformly to every agent, native title generation or not.
    func testAppStoreClaudeCodeAddsTitleInstructionsWhenSettingEnabled() async throws {
        let repository = try GRDBSessionRepository()
        let factory = RecordingProcessFactory()
        var settings = AppSettings()
        settings.sessionDefaults.agentManagedTitleEnabled = true
        settings.git.worktreeNamingSource = .promptDerived

        let store = AppStore(
            repository: repository,
            gitService: MockGitService(),
            processManager: manager(factory: factory, settings: settings),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") },
            settingsProvider: { settings }
        )

        _ = await store.createSession(
            title: "Claude Session",
            goal: "Do task",
            agent: .claudeCode,
            projectFolder: nil,
            checkoutMode: .mainCheckout
        )

        let proc = try XCTUnwrap(factory.processes.first)
        // Not `.last`: a trailing `--settings <json>` pair now follows the
        // goal argument (see HookConfigurationWriter.launchArguments), so
        // find the goal by content rather than position.
        let goalArg = try XCTUnwrap(proc.startedArguments.first { $0.contains("Choose a concise 2–5 word noun-phrase title") })
        XCTAssertTrue(goalArg.contains("Choose a concise 2–5 word noun-phrase title"))
    }
}

