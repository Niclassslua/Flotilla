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

    func locate(_ name: String) -> URL? { executable }
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
    func testMissingGeminiIsDetectedButExcludedFromWarningItems() {
        let viewModel = StartupCheckViewModel(
            locator: SelectiveExecutableLocator(
                availableNames: ["git", "tmux", "gh", "claude", "codex"]
            )
        )

        XCTAssertEqual(viewModel.missingAgents, [.geminiCLI])
        XCTAssertTrue(viewModel.warningItems.isEmpty)
    }

    func testOtherMissingAgentStillAppearsInWarningItems() {
        let viewModel = StartupCheckViewModel(
            locator: SelectiveExecutableLocator(
                availableNames: ["git", "tmux", "gh", "claude", "gemini"]
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
            locator: FixedExecutableLocator(executable: URL(fileURLWithPath: "/usr/bin/env")),
            processFactory: factory,
            settingsProvider: { settings }
        )

        let model = session()
        let process = try manager.start(session: model)
        let mock = try XCTUnwrap(process as? MockPTYProcess)

        XCTAssertEqual(mock.startedExecutable?.path, "/usr/bin/env")
        XCTAssertEqual(mock.startedArguments, ["--profile", "careful"])
        XCTAssertEqual(mock.startedWorkingDirectory, model.workingDirectory)
        XCTAssertEqual(mock.sentInput, [Data("Resolve every compiler error\n".utf8)])
    }

    func testMissingAgentFailsTruthfullyWithoutCreatingFallbackProcess() {
        let factory = RecordingProcessFactory()
        let manager = SessionProcessManager(
            locator: FixedExecutableLocator(executable: nil),
            processFactory: factory
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
            locator: FixedExecutableLocator(executable: URL(fileURLWithPath: "/usr/bin/env")),
            processFactory: factory
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
            locator: FixedExecutableLocator(executable: URL(fileURLWithPath: "/usr/bin/env")),
            processFactory: factory
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
            locator: FixedExecutableLocator(executable: URL(fileURLWithPath: "/usr/bin/env")),
            processFactory: factory
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
        XCTAssertEqual(factory.processes.first?.sentInput, [Data("Find the race\n".utf8)])
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

    func testScrollbackIsCappedAndPersisted() async throws {
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
        let oversized = Data(repeating: 0x41, count: 2 * 1_024 * 1_024 + 128)

        store.appendTerminalOutput(oversized, toSessionID: session.id)
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(store.sessions.first?.terminalScrollback.count, 2 * 1_024 * 1_024)
        XCTAssertEqual(try repository.loadAll().sessions.first?.terminalScrollback.count, 2 * 1_024 * 1_024)
    }
}
