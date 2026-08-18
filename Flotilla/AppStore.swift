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
    private(set) var kanbanBoards: [KanbanBoard] = []
    var selectedSessionID: UUID?
    var selectedProjectID: UUID?
    var selectedKanbanBoardID: UUID?
    var lastCreationError: String?
    var lastOperationError: String?

    let repository: SessionRepository
    let gitService: GitServiceProtocol
    let diffStatStore: DiffStatStore
    private let processManager: SessionProcessManager
    /// A closure, not a frozen value, so a Settings change to the worktree
    /// base directory takes effect on the very next session creation
    /// without needing to relaunch the app.
    private let worktreeBaseDirectoryProvider: () -> URL
    private let worktreePlanner = WorktreePlanner()
    private let statusMachine = SessionStatusMachine()
    private var scrollbackSaveTasks: [UUID: Task<Void, Never>] = [:]
    private static let maximumScrollbackBytes = 256 * 1_024  // 256 KB ring buffer
    private static let scrollbackTrimSlack = 64 * 1_024
    private static let scrollbackSaveDebounce = Duration.milliseconds(2000) // 2 s

    /// Live terminal output, kept out of the observed `sessions` array.
    ///
    /// `sessions` is an `@Observable`-tracked property read by most of the
    /// view hierarchy (session lists, grid tiles, activity strips). PTY
    /// output arrives many times per rendered frame from a chatty TUI, and
    /// mutating `sessions` on every chunk used to re-evaluate that entire
    /// hierarchy at PTY frequency instead of display frequency — the root
    /// cause of the terminal's dropped frame rate. `terminalScrollback` on a
    /// `Session` remains the source of truth for what gets persisted; this
    /// dictionary is the fast, unobserved path terminal output actually
    /// flows through, merged back into a `Session` only at save time.
    @ObservationIgnored
    private var liveScrollback: [UUID: Data] = [:]

    init(
        repository: SessionRepository,
        gitService: GitServiceProtocol,
        processManager: SessionProcessManager,
        worktreeBaseDirectoryProvider: @escaping () -> URL
    ) {
        self.repository = repository
        self.gitService = gitService
        self.diffStatStore = DiffStatStore(gitService: gitService)
        self.processManager = processManager
        self.worktreeBaseDirectoryProvider = worktreeBaseDirectoryProvider
        processManager.eventHandler = { [weak self] event in
            self?.handleProcessEvent(event)
        }
        reload()
        loadKanbanBoards()
    }

    /// The literal home directory (`FileManager.default.homeDirectoryForCurrentUser`)
    /// must never be handed to an agent CLI subprocess as its working
    /// directory: the CLI does its own startup scan of that directory for
    /// project context, and since `Desktop`/`Downloads`/`Music`/`Pictures`/
    /// `Movies` are direct children of home, that scan walks straight into
    /// every TCC-protected folder — triggering "Allow access" system prompts
    /// attributed to Flotilla, invisible to any of Flotilla's own file-scan
    /// logging since the read happens inside the child process. A dedicated
    /// subdirectory keeps a "General Session" (no project folder) usable
    /// without ever exposing those folders to the CLI's own file walk.
    private static func generalSessionWorkingDirectory() -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".flotilla", isDirectory: true)
            .appendingPathComponent("general-session", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func reload() {
        do {
            let loaded = try repository.loadAll()
            projects = loaded.projects
            sessions = loaded.sessions
            for session in loaded.sessions where liveScrollback[session.id] == nil {
                liveScrollback[session.id] = session.terminalScrollback
            }
        } catch {
            lastOperationError = "Session data could not be loaded: \(error.localizedDescription)"
            return
        }

        // One-time migration: sessions created before the fix above have the
        // raw home directory persisted as their working directory. Redirect
        // them to the safe scratch directory before their process restarts,
        // rather than only fixing newly-created sessions.
        let rawHomeDirectory = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        for index in sessions.indices where sessions[index].workingDirectory.standardizedFileURL == rawHomeDirectory {
            sessions[index].workingDirectory = Self.generalSessionWorkingDirectory()
            try? repository.save(mergingLiveScrollback(sessions[index]))
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
                    try repository.save(mergingLiveScrollback(sessions[index]))
                } catch {
                    lastOperationError = "\(error.localizedDescription)"
                }
                lastOperationError = error.localizedDescription
            }
        }
    }

    func createKanbanBoard(_ board: KanbanBoard) throws {
        try repository.saveKanbanBoard(board)
    }

    func loadKanbanBoards() {
        do {
            kanbanBoards = try repository.loadKanbanBoards()
            // Ensure we have a global board
            if !kanbanBoards.contains(where: { $0.projectID == nil }) {
                let globalBoard = try repository.getOrCreateDefaultKanbanBoard(forProject: nil, name: "All Projects")
                kanbanBoards.append(globalBoard)
            }
            // Ensure each project has a board
            for project in projects {
                if !kanbanBoards.contains(where: { $0.projectID == project.id }) {
                    let board = try repository.getOrCreateDefaultKanbanBoard(forProject: project.id, name: project.name)
                    kanbanBoards.append(board)
                }
            }
            // Select first board if none selected
            if selectedKanbanBoardID == nil {
                selectedKanbanBoardID = kanbanBoards.first?.id
            }
        } catch {
            lastOperationError = "Kanban boards could not be loaded: \(error.localizedDescription)"
        }
    }

    var selectedKanbanBoard: KanbanBoard? {
        kanbanBoards.first { $0.id == selectedKanbanBoardID }
    }

    func selectKanbanBoard(_ boardID: UUID) {
        selectedKanbanBoardID = boardID
    }

    func selectKanbanBoard(forProject projectID: UUID?) {
        if let board = kanbanBoards.first(where: { $0.projectID == projectID }) {
            selectedKanbanBoardID = board.id
        }
    }

    func saveKanbanBoard(_ board: KanbanBoard) {
        do {
            try repository.saveKanbanBoard(board)
            if let index = kanbanBoards.firstIndex(where: { $0.id == board.id }) {
                kanbanBoards[index] = board
            }
        } catch {
            lastOperationError = "Kanban board could not be saved: \(error.localizedDescription)"
        }
    }

    func updateKanbanBoardColumnMode(_ mode: KanbanColumnMode) {
        guard var board = selectedKanbanBoard else { return }
        board.columnMode = mode
        // Reset custom columns based on new mode
        switch mode {
        case .status:
            board.customColumns = KanbanColumn.defaultStatusColumns()
        case .agents:
            board.customColumns = KanbanColumn.defaultAgentColumns()
        case .workflow:
            board.customColumns = KanbanColumn.defaultWorkflowColumns()
        case .custom:
            // Keep existing custom columns
            break
        }
        board.updatedAt = Date()
        saveKanbanBoard(board)
    }

    func updateKanbanCardOrder(_ cardOrder: [String: Int]) {
        guard var board = selectedKanbanBoard else { return }
        board.cardOrder = cardOrder
        board.updatedAt = Date()
        saveKanbanBoard(board)
    }

    func moveSessionToColumn(sessionID: UUID, columnID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              var board = selectedKanbanBoard else { return }

        // Update session
        var session = sessions[sessionIndex]
        if board.columnMode == .custom {
            session.kanbanColumnID = columnID
        }
        sessions[sessionIndex] = session
        do {
            try repository.save(mergingLiveScrollback(session))
        } catch {
            lastOperationError = "Session could not be saved: \(error.localizedDescription)"
        }

        // Update board card order - assign next available position in the column
        // Count sessions already in this column (excluding the one being moved)
        var cardOrder = board.cardOrder
        _ = board.customColumns.first(where: { $0.id == columnID })
        let existingInColumn = sessions.filter { s in
            s.kanbanColumnID == columnID && s.id != sessionID
        }
        let nextOrder = existingInColumn.count
        cardOrder[sessionID.uuidString] = nextOrder
        board.cardOrder = cardOrder
        board.updatedAt = Date()
        saveKanbanBoard(board)
    }

    func moveSessionToStatus(sessionID: UUID, status: SessionStatus) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var session = sessions[sessionIndex]
        session = statusMachine.transition(session, to: status)
        sessions[sessionIndex] = session
        do {
            try repository.save(mergingLiveScrollback(session))
        } catch {
            lastOperationError = "Session could not be saved: \(error.localizedDescription)"
        }
    }

    func moveSessionToAgent(sessionID: UUID, agent: AgentKind) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var session = sessions[sessionIndex]
        session.agent = agent
        sessions[sessionIndex] = session
        do {
            try repository.save(mergingLiveScrollback(session))
        } catch {
            lastOperationError = "Session could not be saved: \(error.localizedDescription)"
        }
        // Restart with new agent
        restartSession(sessionID: sessionID)
    }

    func moveSessionToWorkflowStage(sessionID: UUID, stage: WorkflowStage) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var session = sessions[sessionIndex]
        session.workflowStage = stage
        sessions[sessionIndex] = session
        do {
            try repository.save(mergingLiveScrollback(session))
        } catch {
            lastOperationError = "Session could not be saved: \(error.localizedDescription)"
        }
    }

    func getColumnsForBoard(_ board: KanbanBoard) -> [KanbanColumn] {
        switch board.columnMode {
        case .status:
            return KanbanColumn.defaultStatusColumns()
        case .agents:
            return KanbanColumn.defaultAgentColumns()
        case .workflow:
            return KanbanColumn.defaultWorkflowColumns()
        case .custom:
            return board.customColumns.sorted { $0.order < $1.order }
        }
    }

    func getSessionsForColumn(_ column: KanbanColumn, board: KanbanBoard) -> [Session] {
        let relevantSessions: [Session]
        if let projectID = board.projectID {
            relevantSessions = sessions.filter { $0.projectID == projectID }
        } else {
            relevantSessions = sessions
        }

        return relevantSessions.filter { session in
            switch board.columnMode {
            case .status:
                return column.statusFilter == session.status
            case .agents:
                return column.agentFilter == session.agent
            case .workflow:
                return column.workflowStageFilter == session.workflowStage
            case .custom:
                return column.id == session.kanbanColumnID
            }
        }.sorted { lhs, rhs in
            let lhsOrder = board.cardOrder[lhs.id.uuidString] ?? 0
            let rhsOrder = board.cardOrder[rhs.id.uuidString] ?? 0
            return lhsOrder < rhsOrder
        }
    }

    /// The live process backing a session, if one has been started.
    func process(for sessionID: UUID) -> PTYProcessProtocol? {
        processManager.process(for: sessionID)
    }
    // ... rest of the file

    /// Drives the real output-observation pipeline in UI automation without
    /// turning typed user input into fake agent output. This is unavailable
    /// outside an explicit UI-testing launch and never touches production
    /// processes.
    func simulateWaitingPromptForUITesting(sessionTitle: String) {
        #if DEBUG
        let isUITesting = ProcessInfo.processInfo.environment["UI_TESTING"] == "1"
        #else
        let isUITesting = false
        #endif
        guard isUITesting,
              let session = sessions.first(where: { $0.title == sessionTitle }),
              let process = processManager.process(for: session.id) as? MockPTYProcess else { return }
        process.simulateOutput("Do you want to continue? (y/n) ")
    }

    /// Seeds a session with `.crashed` status and a mock process that
    /// will immediately terminate on restart, allowing UI tests to exercise
    /// the restart button flow end-to-end. Only available under `UI_TESTING=1`.
    func simulateCrashedSessionForUITesting(sessionTitle: String) {
        #if DEBUG
        let isUITesting = ProcessInfo.processInfo.environment["UI_TESTING"] == "1"
        #else
        let isUITesting = false
        #endif
        guard isUITesting,
              let index = sessions.firstIndex(where: { $0.title == sessionTitle }) else { return }
        // Mark as crashed so the UI shows the restart affordance
        sessions[index] = statusMachine.transition(sessions[index], to: .crashed)
        // Replace the mock process with one that simulates a crash on start
        if let process = processManager.process(for: sessions[index].id) as? MockPTYProcess {
            process.simulateCrash()
        }
        do {
            try repository.save(mergingLiveScrollback(sessions[index]))
        } catch {
            lastOperationError = error.localizedDescription
        }
    }

    /// Applies a status observed by `HookCoordinator`, going through
    /// `SessionStatusMachine` so illegal transitions (e.g. a heuristic
    /// false-positive after the session already finished) are ignored
    /// rather than corrupting state.
    /// The terminal output a session's renderer should replay, preferring
    /// the live buffer over whatever `terminalScrollback` last persisted.
    func scrollback(for sessionID: UUID) -> Data {
        liveScrollback[sessionID] ?? sessions.first(where: { $0.id == sessionID })?.terminalScrollback ?? Data()
    }

    /// Returns `session` with its `terminalScrollback` replaced by the live
    /// buffer, if any. Every `repository.save` of a session pulled from
    /// `sessions` must go through this — `sessions[index].terminalScrollback`
    /// is not kept current (see `liveScrollback`), so saving it unmerged
    /// would overwrite the persisted history with a stale, possibly empty,
    /// snapshot.
    private func mergingLiveScrollback(_ session: Session) -> Session {
        guard let live = liveScrollback[session.id] else { return session }
        var session = session
        session.terminalScrollback = live
        return session
    }

    func applyObservedStatus(_ status: SessionStatus, toSessionID sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        // Observed status is a level, not an edge: the observer re-reports
        // `.working` for every chunk a streaming agent produces. Filtering
        // no-ops here keeps them out of the machine, which treats a
        // self-transition as illegal and logs each one.
        guard sessions[index].status != status else { return }
        let updated = statusMachine.transition(sessions[index], to: status)
        guard updated.status != sessions[index].status else { return }
        sessions[index] = updated
        do {
            try repository.save(mergingLiveScrollback(updated))
        } catch {
            lastOperationError = "Session status could not be saved: \(error.localizedDescription)"
        }
    }

    /// Appends to the live scrollback buffer only — `sessions` is untouched,
    /// so a chatty PTY no longer invalidates the observed session list on
    /// every chunk. The debounced task below is the only place this reaches
    /// `sessions` (read-only, to source the rest of the `Session` fields for
    /// the row it's about to persist) or the repository.
    func appendTerminalOutput(_ data: Data, toSessionID sessionID: UUID) {
        guard !data.isEmpty, sessions.contains(where: { $0.id == sessionID }) else { return }
        var buffer = liveScrollback[sessionID] ?? Data()
        buffer.append(data)
        // Trim with slack rather than back down to the cap on every chunk:
        // turns an O(chunks) sequence of front-removals into an amortized
        // O(1) one, at the cost of briefly overshooting the cap.
        if buffer.count > Self.maximumScrollbackBytes + Self.scrollbackTrimSlack {
            buffer = Data(buffer.suffix(Self.maximumScrollbackBytes))
        }
        liveScrollback[sessionID] = buffer
        scrollbackSaveTasks[sessionID]?.cancel()
        scrollbackSaveTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: Self.scrollbackSaveDebounce)
            guard !Task.isCancelled, let self else { return }
            guard let index = self.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
            do {
                try self.repository.save(self.mergingLiveScrollback(self.sessions[index]))
            } catch {
                self.lastOperationError = "Terminal history could not be saved: \(error.localizedDescription)"
            }
        }
    }

    func restartSession(sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        lastOperationError = nil
        // Terminate existing process first, then destroy any tmux session
        // this session may still have — including one from a previous app
        // run that this manager instance has no record of. Otherwise
        // `new-session -A` below would reattach to that stale session (and
        // its dead or superseded agent) instead of launching a fresh one.
        processManager.terminate(sessionID: sessionID)
        processManager.killServerSideSession(sessionID: sessionID)
        do {
            try processManager.start(session: sessions[index], deliverGoal: false)
            let updated = statusMachine.transition(sessions[index], to: .working)
            sessions[index] = updated
            try repository.save(mergingLiveScrollback(updated))
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
        fileScanLog.notice("addProject: rootPath=\(folder.path, privacy: .public)")
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
    /// Worktree cleanup is best-effort: if it fails the session is still
    /// deleted, and the failure is surfaced as a warning.
    func deleteSession(
        sessionID: UUID,
        deleteWorktree: Bool,
        deleteBranch: Bool = true
    ) async {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        lastOperationError = nil

        processManager.terminate(sessionID: sessionID)
        processManager.killServerSideSession(sessionID: sessionID)

        var worktreeCleanupWarning: String?
        if deleteWorktree, let worktree = session.worktree {
            do {
                try await gitService.removeWorktree(
                    at: worktree.worktreePath,
                    in: worktree.baseCheckoutPath,
                    branch: worktree.branchName,
                    deleteBranch: deleteBranch
                )
            } catch {
                worktreeCleanupWarning = "The session was deleted, but its worktree could not be fully removed: \(error.localizedDescription)"
            }
        }

        if let worktreeCleanupWarning {
            // The worktree is still on disk and git-locked — deleting the
            // session would orphan it with no way to recover it through the
            // UI. Keep the session and bring its process back up so the user
            // can retry the deletion once the lock is released.
            lastOperationError = worktreeCleanupWarning
            _ = try? processManager.start(session: session, deliverGoal: false)
            return
        }

        do {
            try repository.delete(sessionID: sessionID)
        } catch {
            lastOperationError = "The session could not be deleted: \(error.localizedDescription)"
            return
        }

        scrollbackSaveTasks[sessionID]?.cancel()
        scrollbackSaveTasks[sessionID] = nil
        liveScrollback[sessionID] = nil

        if selectedSessionID == sessionID {
            selectedSessionID = nil
        }
        sessions.removeAll { $0.id == sessionID }

        if let worktreeCleanupWarning {
            lastOperationError = worktreeCleanupWarning
        }
    }

    /// Creates (and immediately starts) a new session: saves the project if
    /// it's new, resolves main-checkout-vs-new-worktree via `WorktreePlanner`,
    /// starts the selected agent's real PTY-backed process, and selects it.
    /// Returns the ID of the created session, or nil if creation failed.
    func createSession(
        title: String,
        goal: String,
        agent: AgentKind,
        model: String? = nil,
        effort: AgentEffort? = nil,
        projectFolder: URL?,
        checkoutMode: CheckoutMode,
        deliverGoal: Bool = true
    ) async -> UUID? {
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
                workingDirectory = Self.generalSessionWorkingDirectory()
            }

            var session = Session(
                title: title,
                goal: goal,
                agent: agent,
                model: model,
                effort: effort,
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
            return session.id
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
            return nil
        }
    }

    private func handleProcessEvent(_ event: SessionProcessManager.SessionProcessEvent) {
        switch event {
        case let .terminated(sessionID, exitCode):
            applyObservedStatus(exitCode == 0 ? .finished : .crashed, toSessionID: sessionID)
        case .launchedWithoutTmux:
            lastOperationError = "tmux is running but not answering clients, so the session was started without it. It will work normally, but will not survive quitting Flotilla."
        }
    }
}

private extension SessionStatus {
    var isTerminal: Bool {
        self == .finished || self == .crashed
    }
}
