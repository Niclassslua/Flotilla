import XCTest
import SessionKit
import ProcessKit
import GitKit
import PersistenceKit
import SettingsKit
import TerminalKit
import HooksKit
@testable import Flotilla

@MainActor
final class AppStoreLifecycleTests: XCTestCase {
    private func manager(factory: RecordingProcessFactory) -> SessionProcessManager {
        SessionProcessManager(
            locator: AppLayerExecutableLocator(
                executable: URL(fileURLWithPath: "/usr/bin/env")
            ),
            processFactory: factory,
            tmuxServerProbe: AppLayerTmuxServerProbe(usable: false)
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
        // A freshly launched session has no status until the observation
        // pipeline sees the agent do something — it must not be optimistically
        // marked working (or, via a boot-screen misread, ready for review).
        XCTAssertNil(store.sessions.first?.status)
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
        XCTAssertEqual(
            factory.processes.first?.startedEnvironment[HookConfigurationWriter.eventFileEnvironmentKey],
            HookConfigurationWriter.eventFilePath(
                for: createdSession.id,
                supportDirectory: TmuxSessionWrapping.defaultSupportDirectory()
            ).path
        )
        XCTAssertTrue(factory.processes.first?.sentInput.isEmpty == true)
    }

    /// "Launch & Stay Here" forwards `selectAfterCreating: false`: the session
    /// is created and running, but selection stays put so the fleet/home view
    /// it was launched from doesn't get dragged onto the new session.
    func testLaunchWithoutSelectingLeavesSelectionAlone() async throws {
        let repository = try GRDBSessionRepository()
        let factory = RecordingProcessFactory()
        let store = AppStore(
            repository: repository,
            gitService: MockGitService(),
            processManager: manager(factory: factory),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") }
        )

        await store.createSession(
            title: "Background chore",
            goal: "Run in the background",
            agent: .claudeCode,
            projectFolder: nil,
            checkoutMode: .mainCheckout,
            selectAfterCreating: false
        )

        XCTAssertNil(store.lastCreationError)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertNil(store.sessions.first?.status, "a just-launched session has no status yet")
        XCTAssertNil(store.selectedSessionID, "\"Launch & Stay Here\" must not change the current selection")
    }

    func testObservedWaitingReasonUpdatesAndPersistsWithoutAStatusChange() async throws {
        let repository = try GRDBSessionRepository()
        let factory = RecordingProcessFactory()
        let store = AppStore(
            repository: repository,
            gitService: MockGitService(),
            processManager: manager(factory: factory),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") }
        )
        await store.createSession(
            title: "Reason detail",
            goal: "Exercise status detail",
            agent: .codexCLI,
            projectFolder: nil,
            checkoutMode: .mainCheckout
        )
        let sessionID = try XCTUnwrap(store.sessions.first?.id)

        store.applyObservedStatus(.waitingForInput, waitingReason: .permission, toSessionID: sessionID)
        XCTAssertEqual(store.sessions.first?.waitingReason, .permission)

        store.applyObservedStatus(.waitingForInput, waitingReason: .question, toSessionID: sessionID)
        XCTAssertEqual(store.sessions.first?.waitingReason, .question)
        XCTAssertEqual(try repository.loadAll().sessions.first?.waitingReason, .question)

        store.applyObservedStatus(.readyForReview, toSessionID: sessionID)
        XCTAssertNil(store.sessions.first?.waitingReason)
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
            locator: AppLayerExecutableLocator(executable: URL(fileURLWithPath: "/usr/bin/env")),
            processFactory: factory,
            tmuxServerProbe: AppLayerTmuxServerProbe(usable: false),
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

        XCTAssertEqual(store.sessions.first?.status, .readyForReview)
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
            status: .readyForReview
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
            status: .readyForReview
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
            status: .readyForReview
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

    /// Process restoration is launch-time recovery, not something a data
    /// refresh does. `reload()` runs after every session creation, so if it
    /// still restarted processes, each new session would spawn a duplicate
    /// process for every session already on screen.
    func testReloadRefreshesDataWithoutRestartingProcesses() async throws {
        let repository = try GRDBSessionRepository()
        try repository.save(Session(
            title: "Restored",
            goal: "Keep going",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working
        ))

        let factory = RecordingProcessFactory()
        let store = AppStore(
            repository: repository,
            gitService: MockGitService(),
            processManager: manager(factory: factory),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") }
        )

        let afterLaunchRestoration = factory.processes.count
        XCTAssertEqual(afterLaunchRestoration, 1, "launch restores the persisted session once")

        try repository.save(Session(
            title: "Added elsewhere",
            goal: "Added elsewhere",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working
        ))

        XCTAssertTrue(store.reload())

        XCTAssertEqual(store.sessions.count, 2, "the refresh picks up newly persisted data")
        XCTAssertEqual(factory.processes.count, afterLaunchRestoration,
                       "a refresh must not start any process")
    }

    /// The restored CLI gets a fresh interactive process, but its original
    /// goal is not sent again — replaying it could repeat destructive work on
    /// every launch.
    func testRestorationDoesNotReplayTheOriginalGoal() throws {
        let repository = try GRDBSessionRepository()
        try repository.save(Session(
            title: "Restored",
            goal: "rm the stale caches",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working
        ))

        let factory = RecordingProcessFactory()
        _ = AppStore(
            repository: repository,
            gitService: MockGitService(),
            processManager: manager(factory: factory),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") }
        )

        let process = try XCTUnwrap(factory.processes.first)
        XCTAssertFalse(process.startedArguments.contains("rm the stale caches"))
        XCTAssertTrue(process.sentInput.isEmpty)
    }
}
