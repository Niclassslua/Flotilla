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
final class AgentManagedWorktreeAndTitleTests: XCTestCase {
    private struct StubNameGenerator: SessionNameGenerating {
        let result: String?
        func name(for goal: String) async -> String? { result }
    }

    func testAppleIntelligenceNameIsAppliedBeforeWorktreeCreation() async throws {
        let repository = try GRDBSessionRepository()
        let factory = RecordingProcessFactory()
        let settings = AppSettings()
        let gitService = MockGitService()
        let store = AppStore(
            repository: repository,
            gitService: gitService,
            processManager: manager(factory: factory, settings: settings),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") },
            settingsProvider: { settings },
            nameGenerator: StubNameGenerator(result: "Session naming pipeline")
        )

        let createdID = await store.createSession(
            title: "First line of a much longer request",
            goal: "Improve naming from the full request",
            agent: .codexCLI,
            projectFolder: URL(fileURLWithPath: "/tmp/name-project"),
            checkoutMode: .newWorktree
        )
        let id = try XCTUnwrap(createdID)
        let session = try XCTUnwrap(store.sessions.first { $0.id == id })
        let branch = try XCTUnwrap(session.worktree?.branchName)
        XCTAssertEqual(session.title, "Session naming pipeline")
        XCTAssertTrue(branch.hasPrefix("flotilla/session-naming-pipeline-"))
        XCTAssertEqual(gitService.createWorktreeCalls.first?.branch, branch)
        XCTAssertEqual(try repository.loadAll().sessions.first { $0.id == id }?.title, "Session naming pipeline")
    }

    func testUnavailableAppleIntelligenceFallsBackToPromptForTitleAndWorktree() async throws {
        let repository = try GRDBSessionRepository()
        let factory = RecordingProcessFactory()
        let settings = AppSettings()
        let gitService = MockGitService()
        let store = AppStore(
            repository: repository,
            gitService: gitService,
            processManager: manager(factory: factory, settings: settings),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") },
            settingsProvider: { settings },
            nameGenerator: StubNameGenerator(result: nil)
        )

        let createdID = await store.createSession(
            title: "Prompt title",
            goal: "A specific long request",
            agent: .codexCLI,
            projectFolder: URL(fileURLWithPath: "/tmp/name-project"),
            checkoutMode: .newWorktree
        )
        let id = try XCTUnwrap(createdID)
        let session = try XCTUnwrap(store.sessions.first { $0.id == id })
        XCTAssertEqual(session.title, "Prompt title")
        XCTAssertTrue(try XCTUnwrap(session.worktree?.branchName).hasPrefix("flotilla/prompt-title-"))
    }

    private func manager(
        factory: RecordingProcessFactory,
        settings: AppSettings = AppSettings()
    ) -> SessionProcessManager {
        SessionProcessManager(
            locator: AppLayerExecutableLocator(
                executable: URL(fileURLWithPath: "/usr/bin/env")
            ),
            processFactory: factory,
            settingsProvider: { settings },
            tmuxServerProbe: AppLayerTmuxServerProbe(usable: false)
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
        let combinedGoal = try XCTUnwrap(proc.startedArguments.first { $0.contains("Do the work") })
        XCTAssertTrue(combinedGoal.hasPrefix("Before starting, write to"))
        XCTAssertTrue(combinedGoal.contains("Do the work"))
    }

    func testAppStoreAgentManagedWorktreeAppliesReportedMetadata() async throws {
        let repository = try GRDBSessionRepository()
        let factory = RecordingProcessFactory()
        var settings = AppSettings()
        settings.sessionDefaults.namingSource = .agentManaged
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
        gitService.worktreesToReturn.append(
            GitWorktree(branch: "flotilla/agent-chosen-slug", path: chosenWorktreeURL, isMainWorktree: false)
        )
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
        let repository = try GRDBSessionRepository()
        let factory = RecordingProcessFactory()
        var settings = AppSettings()
        settings.sessionDefaults.namingSource = .agentManaged
        let gitService = MockGitService()

        let store = AppStore(
            repository: repository,
            gitService: gitService,
            processManager: manager(factory: factory, settings: settings),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") },
            settingsProvider: { settings },
            metadataMonitor: SessionMetadataMonitor(timing: .init(fallbackAfter: .milliseconds(50), pollChunk: .milliseconds(50)))
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
        try await waitForWorktree(of: unwrappedID, in: store)
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
        gitService.worktreesToReturn.append(
            GitWorktree(branch: "flotilla/agent-chosen-slug", path: chosenWorktreeURL, isMainWorktree: false)
        )
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
    /// `namingSource` is `.agentManaged`, our setup-step title instructions
    /// apply uniformly to every agent, native title generation or not.
    func testAppStoreClaudeCodeAddsTitleInstructionsWhenSettingEnabled() async throws {
        let repository = try GRDBSessionRepository()
        let factory = RecordingProcessFactory()
        var settings = AppSettings()
        settings.sessionDefaults.namingSource = .agentManaged

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

    func testAppStoreRejectsSelfReportPointingToRootOrMainCheckout() async throws {
        let repository = try GRDBSessionRepository()
        let factory = RecordingProcessFactory()
        let gitService = MockGitService()
        var settings = AppSettings()
        settings.sessionDefaults.namingSource = .agentManaged

        let projectFolder = URL(fileURLWithPath: "/tmp/safe-project")
        // Main checkout is main worktree
        gitService.worktreesToReturn = [
            GitWorktree(branch: "main", path: projectFolder, isMainWorktree: true)
        ]

        let store = AppStore(
            repository: repository,
            gitService: gitService,
            processManager: manager(factory: factory, settings: settings),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") },
            settingsProvider: { settings },
            metadataMonitor: SessionMetadataMonitor(timing: .init(fallbackAfter: .milliseconds(50), pollChunk: .milliseconds(50)))
        )

        let sessionID = await store.createSession(
            title: "Dangerous Report Session",
            goal: "Do task",
            agent: .codexCLI,
            projectFolder: projectFolder,
            checkoutMode: .newWorktree
        )
        let unwrappedID = try XCTUnwrap(sessionID)

        // Wait for fallback worktree to be created
        try await waitForWorktree(of: unwrappedID, in: store)
        let fallbackWorktree = store.sessions.first(where: { $0.id == unwrappedID })?.worktree
        XCTAssertNotNil(fallbackWorktree, "Fallback worktree should exist")

        let supportDir = TmuxSessionWrapping.defaultSupportDirectory()
        let descPath = AgentSelfReportCoordinator.descriptorPath(for: unwrappedID, supportDirectory: supportDir)
        try FileManager.default.createDirectory(at: descPath.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Simulate malicious or buggy agent reporting root "/" or project folder
        let maliciousDescriptor = AgentSelfReportDescriptor(
            title: "Malicious Worktree Report",
            branch: "main",
            worktreePath: "/"
        )
        try JSONEncoder().encode(maliciousDescriptor).write(to: descPath)

        try await Task.sleep(for: .milliseconds(200))

        let currentSession = try XCTUnwrap(store.sessions.first(where: { $0.id == unwrappedID }))
        // Worktree should NOT be updated to "/"
        XCTAssertNotEqual(currentSession.worktree?.worktreePath.path, "/")
        // The fallback worktree must remain intact
        XCTAssertEqual(currentSession.worktree?.worktreePath, fallbackWorktree?.worktreePath)
        // Fallback worktree should not have been removed
        XCTAssertEqual(gitService.removeWorktreeCalls.count, 0)

        AgentSelfReportCoordinator.clearDescriptor(for: unwrappedID, supportDirectory: supportDir)
    }

    /// The mock records `createWorktree` before returning, and the store
    /// assigns the worktree only after that await resumes — so wait for the
    /// session itself, not the recorded call.
    private func waitForWorktree(of sessionID: UUID, in store: AppStore) async throws {
        for _ in 0..<100 {
            if store.sessions.first(where: { $0.id == sessionID })?.worktree != nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
