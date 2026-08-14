import Foundation
import Observation
import SessionKit
import GitKit
import ProcessKit

@Observable
@MainActor
final class AppStore {
    private(set) var projects: [Project] = []
    private(set) var sessions: [Session] = []
    var selectedSessionID: UUID?
    var lastCreationError: String?
    var lastOperationError: String?

    private let repository: SessionRepository
    let gitService: GitServiceProtocol
    private let processManager: SessionProcessManager
    /// A closure, not a frozen value, so a Settings change to the worktree
    /// base directory takes effect on the very next session creation
    /// without needing to relaunch the app.
    private let worktreeBaseDirectoryProvider: () -> URL
    private let worktreePlanner = WorktreePlanner()
    private let statusMachine = SessionStatusMachine()
    private var scrollbackSaveTasks: [UUID: Task<Void, Never>] = [:]
    private static let maximumScrollbackBytes = 2 * 1_024 * 1_024

    init(
        repository: SessionRepository,
        gitService: GitServiceProtocol,
        processManager: SessionProcessManager,
        worktreeBaseDirectoryProvider: @escaping () -> URL
    ) {
        self.repository = repository
        self.gitService = gitService
        self.processManager = processManager
        self.worktreeBaseDirectoryProvider = worktreeBaseDirectoryProvider
        processManager.eventHandler = { [weak self] event in
            self?.handleProcessEvent(event)
        }
        reload()
    }

    func reload() {
        do {
            let loaded = try repository.loadAll()
            projects = loaded.projects
            sessions = loaded.sessions
        } catch {
            lastOperationError = "Session data could not be loaded: \(error.localizedDescription)"
            return
        }

        for index in sessions.indices where !sessions[index].status.isTerminal {
            do {
                // A restored CLI gets a fresh interactive process, but the
                // original goal is not sent again; replaying it could repeat
                // destructive work after every app launch.
                try processManager.start(session: sessions[index], deliverGoal: false)
            } catch {
                sessions[index] = statusMachine.transition(sessions[index], to: .crashed)
                do {
                    try repository.save(sessions[index])
                } catch {
                    lastOperationError = "\(error.localizedDescription)"
                }
                lastOperationError = error.localizedDescription
            }
        }
    }

    /// The live process backing a session, if one has been started.
    func process(for sessionID: UUID) -> PTYProcessProtocol? {
        processManager.process(for: sessionID)
    }

    /// Drives the real output-observation pipeline in UI automation without
    /// turning typed user input into fake agent output. This is unavailable
    /// outside an explicit UI-testing launch and never touches production
    /// processes.
    func simulateWaitingPromptForUITesting(sessionTitle: String) {
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == "1",
              let session = sessions.first(where: { $0.title == sessionTitle }),
              let process = processManager.process(for: session.id) as? MockPTYProcess else { return }
        process.simulateOutput("Do you want to continue? (y/n) ")
    }

    /// Applies a status observed by `HookCoordinator`, going through
    /// `SessionStatusMachine` so illegal transitions (e.g. a heuristic
    /// false-positive after the session already finished) are ignored
    /// rather than corrupting state.
    func applyObservedStatus(_ status: SessionStatus, toSessionID sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let updated = statusMachine.transition(sessions[index], to: status)
        guard updated.status != sessions[index].status else { return }
        sessions[index] = updated
        do {
            try repository.save(updated)
        } catch {
            lastOperationError = "Session status could not be saved: \(error.localizedDescription)"
        }
    }

    func appendTerminalOutput(_ data: Data, toSessionID sessionID: UUID) {
        guard !data.isEmpty,
              let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].terminalScrollback.append(data)
        if sessions[index].terminalScrollback.count > Self.maximumScrollbackBytes {
            sessions[index].terminalScrollback = Data(
                sessions[index].terminalScrollback.suffix(Self.maximumScrollbackBytes)
            )
        }
        let snapshot = sessions[index]
        scrollbackSaveTasks[sessionID]?.cancel()
        scrollbackSaveTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do {
                try self?.repository.save(snapshot)
            } catch {
                self?.lastOperationError = "Terminal history could not be saved: \(error.localizedDescription)"
            }
        }
    }

    func restartSession(sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        lastOperationError = nil
        do {
            try processManager.start(session: sessions[index], deliverGoal: false)
            let updated = statusMachine.transition(sessions[index], to: .working)
            sessions[index] = updated
            try repository.save(updated)
        } catch {
            lastOperationError = error.localizedDescription
        }
    }

    var selectedSession: Session? {
        sessions.first { $0.id == selectedSessionID }
    }

    func project(for session: Session) -> Project? {
        guard let projectID = session.projectID else { return nil }
        return projects.first { $0.id == projectID }
    }

    func sessions(for project: Project) -> [Session] {
        sessions
            .filter { $0.projectID == project.id }
            .sorted { $0.title < $1.title }
    }

    var generalSessions: [Session] {
        sessions
            .filter { $0.projectID == nil }
            .sorted { $0.title < $1.title }
    }

    /// Imports a local folder as a project without launching a session.
    /// Persistence stays behind `SessionRepository`; views never touch the
    /// database or spawn a process directly.
    func addProject(at folder: URL) {
        let normalized = folder.standardizedFileURL
        if let existing = projects.first(where: { $0.rootPath.standardizedFileURL == normalized }) {
            selectedSessionID = sessions(for: existing).first?.id
            return
        }

        let project = Project(name: normalized.lastPathComponent, rootPath: normalized)
        do {
            try repository.save(project)
            projects.append(project)
            projects.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            lastOperationError = "The project could not be imported: \(error.localizedDescription)"
        }
    }

    /// Deletes a session, terminating its process and — when it has a
    /// worktree and `deleteWorktree` is true — removing the worktree
    /// directory and its branch via `GitServiceProtocol.removeWorktree`.
    func deleteSession(
        sessionID: UUID,
        deleteWorktree: Bool,
        deleteBranch: Bool = true
    ) async {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        lastOperationError = nil

        let wasRunning = processManager.process(for: sessionID)?.isRunning == true

        processManager.terminate(sessionID: sessionID)

        if deleteWorktree, let worktree = session.worktree {
            do {
                try await gitService.removeWorktree(
                    at: worktree.worktreePath,
                    in: worktree.baseCheckoutPath,
                    branch: worktree.branchName,
                    deleteBranch: deleteBranch
                )
            } catch {
                var message = "The session was kept because its worktree could not be removed: \(error.localizedDescription)"
                if wasRunning {
                    do {
                        try processManager.start(session: session, deliverGoal: false)
                    } catch {
                        message += " Its agent could not be resumed: \(error.localizedDescription)"
                        applyObservedStatus(.crashed, toSessionID: sessionID)
                    }
                }
                lastOperationError = message
                return
            }
        }

        do {
            try repository.delete(sessionID: sessionID)
        } catch {
            lastOperationError = "The session could not be deleted: \(error.localizedDescription)"
            return
        }

        if selectedSessionID == sessionID {
            selectedSessionID = nil
        }
        sessions.removeAll { $0.id == sessionID }
    }

    /// Creates (and immediately starts) a new session: saves the project if
    /// it's new, resolves main-checkout-vs-new-worktree via `WorktreePlanner`,
    /// starts the selected agent's real PTY-backed process, and selects it.
    func createSession(
        title: String,
        goal: String,
        agent: AgentKind,
        projectFolder: URL?,
        checkoutMode: CheckoutMode,
        deliverGoal: Bool = true
    ) async {
        lastCreationError = nil
        var createdWorktree: WorktreeInfo?
        do {
            var projectID: UUID?
            var workingDirectory: URL
            var worktreeInfo: WorktreeInfo?

            if let projectFolder {
                let project = projects.first { $0.rootPath == projectFolder }
                    ?? Project(name: projectFolder.lastPathComponent, rootPath: projectFolder)
                if !projects.contains(where: { $0.id == project.id }) {
                    try repository.save(project)
                }
                projectID = project.id

                let decision = worktreePlanner.plan(
                    useNewWorktree: checkoutMode == .newWorktree,
                    projectRoot: projectFolder,
                    worktreeBaseDirectory: worktreeBaseDirectoryProvider(),
                    branchName: BranchNaming.generate(from: title)
                )
                switch decision {
                case .useExistingCheckout(let path):
                    workingDirectory = path
                case .createWorktree(let basePath, let branch, let destination):
                    let worktree = try await gitService.createWorktree(basePath: basePath, branch: branch, destination: destination)
                    workingDirectory = worktree.path
                    worktreeInfo = WorktreeInfo(branchName: worktree.branch, worktreePath: worktree.path, baseCheckoutPath: basePath)
                    createdWorktree = worktreeInfo
                }
            } else {
                workingDirectory = FileManager.default.homeDirectoryForCurrentUser
            }

            var session = Session(
                title: title,
                goal: goal,
                agent: agent,
                projectID: projectID,
                workingDirectory: workingDirectory,
                worktree: worktreeInfo,
                status: .idle
            )
            try processManager.start(session: session, deliverGoal: deliverGoal)
            session = statusMachine.transition(session, to: .working)
            do {
                try repository.save(session)
            } catch {
                processManager.terminate(sessionID: session.id)
                throw error
            }

            reload()
            selectedSessionID = session.id
        } catch {
            var message = error.localizedDescription
            if let createdWorktree {
                do {
                    try await gitService.removeWorktree(
                        at: createdWorktree.worktreePath,
                        in: createdWorktree.baseCheckoutPath,
                        branch: createdWorktree.branchName,
                        deleteBranch: true
                    )
                } catch {
                    message += " The created worktree also needs manual cleanup: \(error.localizedDescription)"
                }
            }
            lastCreationError = message
        }
    }

    private func handleProcessEvent(_ event: SessionProcessManager.SessionProcessEvent) {
        switch event {
        case let .terminated(sessionID, exitCode):
            applyObservedStatus(exitCode == 0 ? .finished : .crashed, toSessionID: sessionID)
        }
    }
}

private extension SessionStatus {
    var isTerminal: Bool {
        self == .finished || self == .crashed
    }
}
