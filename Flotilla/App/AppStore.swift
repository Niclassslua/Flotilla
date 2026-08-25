import Foundation
import Observation
import SessionKit
import GitKit
import ProcessKit
import TerminalKit
import AgentKit
import SettingsKit

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
    /// Called once per clean process exit (never on `.crashed`) after the
    /// session's status has already landed on `.finished` — the app layer
    /// decides whether/how to notify from here, so this stays a plain
    /// closure rather than pulling a notification dependency into AppStore.
    var onSessionFinished: ((Session) -> Void)?

    let repository: SessionRepository
    let gitService: GitServiceProtocol
    let ghService: GhServiceProtocol?
    let diffStatStore: DiffStatStore
    private let processManager: SessionProcessManager
    /// A closure, not a frozen value, so a Settings change to the worktree
    /// base directory takes effect on the very next session creation
    /// without needing to relaunch the app.
    private let worktreeBaseDirectoryProvider: () -> URL
    /// Provides the current `AppSettings` snapshot for features that need
    /// to consult user preferences at runtime (agent-managed worktree naming,
    /// agent-managed session titles). Same closure-not-frozen-value rationale
    /// as `worktreeBaseDirectoryProvider`.
    private let settingsProvider: () -> AppSettings
    private let worktreePlanner = WorktreePlanner()
    private let statusMachine = SessionStatusMachine()
    private var scrollbackSaveTasks: [UUID: Task<Void, Never>] = [:]
    private static let maximumScrollbackBytes = 256 * 1_024  // 256 KB ring buffer
    private static let scrollbackTrimSlack = 64 * 1_024
    private static let scrollbackSaveDebounce = Duration.milliseconds(2000) // 2 s
    @ObservationIgnored
    private var sessionResumeStarts: [UUID: Date] = [:]
    @ObservationIgnored
    private var sessionResumeRetried: Set<UUID> = []

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
        ghService: GhServiceProtocol? = nil,
        processManager: SessionProcessManager,
        worktreeBaseDirectoryProvider: @escaping () -> URL,
        settingsProvider: @escaping () -> AppSettings = { AppSettings() }
    ) {
        self.repository = repository
        self.gitService = gitService
        self.ghService = ghService
        self.diffStatStore = DiffStatStore(gitService: gitService)
        self.processManager = processManager
        self.worktreeBaseDirectoryProvider = worktreeBaseDirectoryProvider
        self.settingsProvider = settingsProvider
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
        if ProcessInfo.processInfo.environment["UI_TESTING"] == "1" {
            let directory = URL(fileURLWithPath: "/tmp/flotilla-uitest-general-session")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
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
            // Reap orphaned tmux sessions left behind by crashes or external deletions
            let activeIDs = Set(loaded.sessions.map(\.id))
            processManager.reapOrphanTmuxSessions(knownSessionIDs: activeIDs)
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
                if sessions[index].agentSessionID != nil {
                    sessionResumeStarts[sessions[index].id] = Date()
                }
                // A restored CLI gets a fresh interactive process, but the
                // original goal is not sent again; replaying it could repeat
                // destructive work after every app launch.
                try processManager.start(session: sessions[index], deliverGoal: false)
            } catch {
                if case .conversationAlreadyActive = error as? SessionProcessManager.LaunchError {
                    sessions[index] = statusMachine.transition(sessions[index], to: .crashed)
                    try? repository.save(mergingLiveScrollback(sessions[index]))
                    lastOperationError = error.localizedDescription
                    continue
                }
                if sessions[index].agentSessionID != nil {
                    sessions[index].agentSessionID = nil
                    try? repository.save(mergingLiveScrollback(sessions[index]))
                    do {
                        try processManager.start(session: sessions[index], deliverGoal: false)
                        lastOperationError = "Previous conversation could not be restored — starting a fresh context."
                        scheduleTitleSync(forSessionID: sessions[index].id)
                        continue
                    } catch {
                        // proceed to crash transition
                    }
                }
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
        if updated.status == .finished {
            onSessionFinished?(updated)
        }
    }

    /// Asynchronously queries the active agent's native storage/API for an
    /// auto-generated session title and session ID, applying both if found.
    func syncAgentSessionMetadata(forSessionID sessionID: UUID) async {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        // Only look for native agent sessions active around or after this session was launched
        let searchSince = session.createdAt.addingTimeInterval(-30)
        if let discovered = await AgentSessionProviderRegistry.default.fetchLatestSession(
            for: session.agent,
            workingDirectory: session.workingDirectory,
            since: searchSince
        ) {
            // Pin the discovered native session ID before title guards
            if let index = sessions.firstIndex(where: { $0.id == sessionID }),
               sessions[index].agentSessionID == nil || sessions[index].agentSessionID?.isEmpty == true {
                sessions[index].agentSessionID = discovered.id
                try? repository.save(mergingLiveScrollback(sessions[index]))
            }

            let discoveredTitle = discovered.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !discoveredTitle.isEmpty else { return }
            guard !discoveredTitle.contains("\n"), discoveredTitle.count <= 120 else { return }
            guard !discoveredTitle.hasPrefix("New session - ") else { return }
            syncDiscoveredTitle(discoveredTitle, toSessionID: sessionID)
        }
    }

    /// Backwards-compatible forwarder
    func syncAgentTitle(forSessionID sessionID: UUID) async {
        await syncAgentSessionMetadata(forSessionID: sessionID)
    }

    /// Spawns a lightweight background retry loop that checks the agent's
    /// native session storage to pick up auto-generated titles and session
    /// IDs as soon as the agent produces them.
    ///
    /// Starts with tight intervals (1s, 2.5s, 5s, 9s, 15s, 25s) to catch the
    /// common case fast, then keeps polling every `steadyStateInterval`
    /// while the session stays active. The steady-state tail matters: an
    /// agent that pauses on an interactive tool-permission prompt (e.g. a
    /// CLI agent asking to approve a shell command) can take far longer than
    /// 25s for a human to notice and respond, and a fixed short schedule
    /// gives up before the agent ever writes its title. Bounded by
    /// `giveUpAfter` so an abandoned-but-still-open session doesn't poll
    /// forever.
    func scheduleTitleSync(forSessionID sessionID: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let burstDelays: [TimeInterval] = [1.0, 2.5, 5.0, 9.0, 15.0, 25.0]
            let steadyStateInterval: TimeInterval = 20.0
            let giveUpAfter: TimeInterval = 1800
            var elapsed: TimeInterval = 0

            for delay in burstDelays {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                elapsed += delay
                guard self.isSessionActive(sessionID) else { return }
                await self.syncAgentSessionMetadata(forSessionID: sessionID)
            }

            while elapsed < giveUpAfter {
                try? await Task.sleep(nanoseconds: UInt64(steadyStateInterval * 1_000_000_000))
                elapsed += steadyStateInterval
                guard self.isSessionActive(sessionID) else { return }
                await self.syncAgentSessionMetadata(forSessionID: sessionID)
            }
        }
    }

    /// Whether a session is still in a state where its agent process is
    /// expected to be doing (or about to do) work — used to decide when a
    /// background poll loop should keep waiting versus give up.
    private func isSessionActive(_ sessionID: UUID) -> Bool {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return false }
        return session.status == .working
            || session.status == .waitingForInput
            || session.status == .idle
    }

    /// Updates a session's title from discovered agent metadata.
    func syncDiscoveredTitle(_ title: String, toSessionID sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, sessions[index].title != trimmed else { return }
        sessions[index].title = trimmed
        do {
            try repository.save(mergingLiveScrollback(sessions[index]))
        } catch {
            lastOperationError = "Session title could not be saved: \(error.localizedDescription)"
        }
    }

    /// Renames a session and persists the update.
    func renameSession(sessionID: UUID, newTitle: String) {
        syncDiscoveredTitle(newTitle, toSessionID: sessionID)
    }

    // MARK: - Agent self-report

    /// Fallback-creating an app-managed worktree only kicks in once the
    /// agent has had this long to write its own descriptor. A shorter
    /// window races an interactive tool-permission prompt (e.g. a CLI
    /// agent asking a human to approve the `git worktree add` command) —
    /// the human can easily take longer than a few seconds to notice and
    /// respond, and firing the fallback mid-approval leaves the session
    /// with a spurious duplicate worktree.
    /// `var`, not `let`: tests override this to a short interval so they
    /// don't have to sleep for real minutes to exercise the fallback path.
    static var selfReportFallbackAfter: Duration = .seconds(180)
    /// Absolute cap on how long a self-report poll loop runs for one
    /// session, so an abandoned-but-still-open session doesn't poll
    /// forever in the background. `var` for the same test-override reason.
    static var selfReportGiveUpAfter: Duration = .seconds(1800)
    /// `var` for the same test-override reason.
    static var selfReportPollChunk: Duration = .seconds(20)

    /// Polls for the agent's self-report descriptor file and applies any
    /// metadata it contains (title, worktree branch/path) to the session.
    ///
    /// Keeps polling in `selfReportPollChunk` increments for as long as the
    /// session is still active. If `wantsWorktree` and the agent hasn't
    /// reported in by `selfReportFallbackAfter`, an app-managed worktree is
    /// created as a stopgap — but polling continues afterward, so if the
    /// agent's own descriptor arrives later (e.g. once a human finally
    /// approves a pending tool-permission prompt) it still wins: the
    /// stopgap worktree is discarded and the agent-reported one takes over.
    private func awaitAgentSelfReport(
        sessionID: UUID,
        descriptorPath: URL,
        wantsWorktree: Bool,
        projectFolder: URL?
    ) async {
        let supportDirectory = TmuxSessionWrapping.defaultSupportDirectory()
        var elapsed: Duration = .zero
        var fallbackWorktree: WorktreeInfo?

        while elapsed < Self.selfReportGiveUpAfter {
            if let descriptor = await AgentSelfReportCoordinator.waitForDescriptor(
                sessionID: sessionID,
                supportDirectory: supportDirectory,
                timeout: Self.selfReportPollChunk
            ) {
                await applySelfReport(descriptor, sessionID: sessionID, projectFolder: projectFolder, replacing: fallbackWorktree)
                return
            }
            elapsed += Self.selfReportPollChunk

            guard sessions.contains(where: { $0.id == sessionID }) else { return }
            let isActive = isSessionActive(sessionID)

            if wantsWorktree, fallbackWorktree == nil, elapsed >= Self.selfReportFallbackAfter || !isActive {
                fallbackWorktree = await fallBackToAppManagedWorktree(sessionID: sessionID, projectFolder: projectFolder)
            }

            if !isActive { return }
        }
    }

    /// Applies a (possibly late-arriving) self-report descriptor. When a
    /// `replacing` fallback worktree is passed, it's removed first so the
    /// agent-reported worktree becomes the session's only one, and the
    /// fallback's warning is cleared since the situation it described has
    /// now resolved itself.
    private func applySelfReport(
        _ descriptor: AgentSelfReportDescriptor,
        sessionID: UUID,
        projectFolder: URL?,
        replacing fallbackWorktree: WorktreeInfo?
    ) async {
        if let fallbackWorktree {
            try? await gitService.removeWorktree(
                at: fallbackWorktree.worktreePath,
                in: fallbackWorktree.baseCheckoutPath,
                branch: fallbackWorktree.branchName,
                deleteBranch: true
            )
            if lastOperationError == Self.fallbackWarning {
                lastOperationError = nil
            }
        }

        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }

        // Apply title (same guards syncAgentSessionMetadata already applies).
        if let reportedTitle = descriptor.title {
            let trimmed = reportedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.contains("\n"), trimmed.count <= 120, sessions[index].title != trimmed {
                sessions[index].title = trimmed
            }
        }

        // Apply worktree metadata.
        if let branch = descriptor.branch, let worktreePathString = descriptor.worktreePath {
            let worktreePath = URL(fileURLWithPath: worktreePathString)
            if let projectFolder {
                sessions[index].worktree = WorktreeInfo(
                    branchName: branch,
                    worktreePath: worktreePath,
                    baseCheckoutPath: projectFolder
                )
                sessions[index].workingDirectory = worktreePath
            }
        }

        do {
            try repository.save(mergingLiveScrollback(sessions[index]))
        } catch {
            lastOperationError = "Agent self-report could not be saved: \(error.localizedDescription)"
        }
    }

    private static let fallbackWarning = "The agent did not create its own worktree in time. "
        + "A worktree was created automatically, but the agent's process is still "
        + "running in the main checkout — files it edits will land there, not in "
        + "the new worktree."

    /// Re-runs today's `WorktreePlanner` + `gitService.createWorktree` flow
    /// when the agent hasn't responded to the self-report request within
    /// `selfReportFallbackAfter`. Returns the worktree it created, so the
    /// caller can discard it later if the agent's own descriptor still
    /// shows up.
    ///
    /// **Known limitation:** by the time this fires, the agent has already
    /// been running — and possibly editing files — directly in the main
    /// checkout, since it was never actually launched into a worktree. The
    /// worktree created here gives the session a `Session.worktree` the
    /// running agent process has no relationship to; its real edits are
    /// still landing in the main checkout. The warning makes this visible
    /// rather than silently presenting the worktree as if it were in use.
    @discardableResult
    private func fallBackToAppManagedWorktree(sessionID: UUID, projectFolder: URL?) async -> WorktreeInfo? {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              let projectFolder else { return nil }

        let branchName = BranchNaming.generate(from: sessions[index].title)
        let decision = worktreePlanner.plan(
            useNewWorktree: true,
            projectRoot: projectFolder,
            worktreeBaseDirectory: worktreeBaseDirectoryProvider(),
            branchName: branchName
        )
        guard case .createWorktree(let basePath, let branch, let destination) = decision else { return nil }
        do {
            let worktree = try await gitService.createWorktree(basePath: basePath, branch: branch, destination: destination)
            let worktreeInfo = WorktreeInfo(
                branchName: worktree.branch,
                worktreePath: worktree.path,
                baseCheckoutPath: basePath
            )
            sessions[index].worktree = worktreeInfo
            sessions[index].workingDirectory = worktree.path
            try repository.save(mergingLiveScrollback(sessions[index]))
            lastOperationError = Self.fallbackWarning
            return worktreeInfo
        } catch {
            lastOperationError = "The agent did not create its own worktree, and the "
                + "automatic fallback also failed: \(error.localizedDescription)"
            return nil
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

    /// Immediately flushes all debounced live scrollback buffers to the persistent
    /// repository, cancelling in-flight debounce timers. Called before app termination
    /// to guarantee zero terminal history loss on Cmd+Q.
    func flushLiveScrollback() {
        for (_, task) in scrollbackSaveTasks {
            task.cancel()
        }
        scrollbackSaveTasks.removeAll()
        for session in sessions {
            if liveScrollback[session.id] != nil {
                try? repository.save(mergingLiveScrollback(session))
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
        // Clear agentSessionID before restart to ensure a completely fresh conversation
        sessions[index].agentSessionID = nil
        let descriptor = AgentCatalog.descriptor(for: sessions[index].agent)
        if case .assignable = descriptor.resume {
            sessions[index].agentSessionID = sessions[index].id.uuidString
        }
        do {
            try processManager.start(session: sessions[index], deliverGoal: false)
            let updated = statusMachine.transition(sessions[index], to: .working)
            sessions[index] = updated
            try repository.save(mergingLiveScrollback(updated))
            scheduleTitleSync(forSessionID: sessionID)
        } catch {
            lastOperationError = error.localizedDescription
        }
    }

    func reattachSession(sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        do {
            try processManager.reattach(session: sessions[index])
        } catch {
            lastOperationError = "Failed to reattach session: \(error.localizedDescription)"
        }
    }

    func customReflowHandler(for sessionID: UUID) -> (@MainActor @Sendable (TerminalPresentation) -> Void)? {
        guard processManager.isTmuxWrapped(sessionID: sessionID) else { return nil }
        return { [weak self] _ in
            self?.processManager.refreshTmuxClient(for: sessionID)
        }
    }

    func resizeHandler(for sessionID: UUID) -> (@MainActor @Sendable (PTYSize) -> Void) {
        return { [weak self] size in
            guard let self else { return }
            self.processManager.verifyAndRecoverResize(
                sessionID: sessionID,
                expectedSize: size,
                onRecoveryFailure: { [weak self] error in
                    self?.lastOperationError = error
                }
            )
        }
    }

    var selectedSession: Session? {
        sessions.first { $0.id == selectedSessionID }
    }

    /// Where new worktrees land. Exposed so the session launcher can show the
    /// destination path *before* the user commits, rather than after the
    /// worktree already exists.
    var worktreeBaseDirectory: URL {
        worktreeBaseDirectoryProvider()
    }

    /// The scratch directory a project-less session runs in. Same accessor
    /// rationale as `worktreeBaseDirectory` — the launcher previews it.
    var generalSessionDirectory: URL {
        Self.generalSessionWorkingDirectory()
    }

    /// Lets the launcher substitute a fixture path for `NSOpenPanel`, which
    /// cannot be driven from a UI test.
    var isUITestingFixtureMode: Bool {
        ProcessInfo.processInfo.environment["UI_TESTING"] == "1"
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
        // Comparing `.path` with a trailing slash trimmed, rather than the
        // `URL`s themselves: `standardizedFileURL` resolves symlinks and
        // `.`/`..` components, but for a path that doesn't exist on disk
        // (nothing here touches the filesystem) it does not reliably erase
        // a bare trailing-slash difference, so two `URL`s naming the same
        // folder can still compare unequal.
        let normalizedPath = Self.trimmedPath(normalized)
        if let existing = projects.first(where: { Self.trimmedPath($0.rootPath.standardizedFileURL) == normalizedPath }) {
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

    /// Removes a project from the library. Sessions associated with the
    /// project are retained as standalone sessions.
    func removeProject(id: UUID) {
        do {
            try repository.delete(projectID: id)
            projects.removeAll { $0.id == id }
            if selectedProjectID == id {
                selectedProjectID = nil
            }
        } catch {
            lastOperationError = "The project could not be removed: \(error.localizedDescription)"
        }
    }

    private static func trimmedPath(_ url: URL) -> String {
        var path = url.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
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
        deliverGoal: Bool = true,
        fetchBeforeCreatingWorktree: Bool = false
    ) async -> UUID? {
        lastCreationError = nil
        var createdWorktree: WorktreeInfo?
        let settings = settingsProvider()
        let agentDescriptor = AgentCatalog.descriptor(for: agent)

        // Determine whether agent-managed features should activate.
        let wantsAgentWorktree = checkoutMode == .newWorktree
            && projectFolder != nil
            && settings.git.worktreeNamingSource == .agentManaged
        let wantsAgentTitle = settings.sessionDefaults.agentManagedTitleEnabled
            && !agentDescriptor.hasNativeTitleGeneration

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

                if wantsAgentWorktree {
                    // Agent-managed worktree: skip WorktreePlanner and launch
                    // in the project root. The agent creates the worktree
                    // itself and reports back via the descriptor file.
                    workingDirectory = projectFolder
                } else {
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
                        if fetchBeforeCreatingWorktree {
                            // Best-effort: an offline machine or a repo with no
                            // remote must not block worktree creation over a
                            // failed fetch.
                            try? await gitService.fetch(at: basePath)
                        }
                        let worktree = try await gitService.createWorktree(basePath: basePath, branch: branch, destination: destination)
                        workingDirectory = worktree.path
                        worktreeInfo = WorktreeInfo(branchName: worktree.branch, worktreePath: worktree.path, baseCheckoutPath: basePath)
                        createdWorktree = worktreeInfo
                    }
                }
            } else {
                workingDirectory = Self.generalSessionWorkingDirectory()
            }

            // Mint the session ID up front so the descriptor path is
            // deterministic before the Session struct exists.
            let sessionID = UUID()
            let supportDirectory = TmuxSessionWrapping.defaultSupportDirectory()

            // Build self-report instructions + descriptor path when either
            // agent-managed feature is active.
            var selfReportInstructions: String?
            var selfReportDescriptorPath: URL?
            if (wantsAgentWorktree || wantsAgentTitle) && deliverGoal {
                let descPath = AgentSelfReportCoordinator.descriptorPath(
                    for: sessionID, supportDirectory: supportDirectory
                )
                AgentSelfReportCoordinator.clearDescriptor(
                    for: sessionID, supportDirectory: supportDirectory
                )
                selfReportDescriptorPath = descPath
                selfReportInstructions = AgentSelfReportCoordinator.instructions(
                    wantsTitle: wantsAgentTitle,
                    wantsWorktree: wantsAgentWorktree,
                    descriptorPath: descPath,
                    projectRoot: projectFolder,
                    worktreeBaseDirectory: wantsAgentWorktree ? worktreeBaseDirectoryProvider() : nil
                )
            }

            var session = Session(
                id: sessionID,
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
            try processManager.start(
                session: session,
                deliverGoal: deliverGoal,
                selfReportInstructions: selfReportInstructions,
                selfReportDescriptorPath: selfReportDescriptorPath
            )
            if case .assignable = agentDescriptor.resume {
                session.agentSessionID = session.id.uuidString
            }
            session = statusMachine.transition(session, to: .working)
            do {
                try repository.save(session)
            } catch {
                processManager.terminate(sessionID: session.id)
                throw error
            }

            reload()
            selectedSessionID = session.id
            scheduleTitleSync(forSessionID: session.id)

            // Kick off background polling for the agent's self-report
            // descriptor when either agent-managed feature is active.
            if let selfReportDescriptorPath, (wantsAgentWorktree || wantsAgentTitle) {
                Task { @MainActor [weak self] in
                    await self?.awaitAgentSelfReport(
                        sessionID: sessionID,
                        descriptorPath: selfReportDescriptorPath,
                        wantsWorktree: wantsAgentWorktree,
                        projectFolder: projectFolder
                    )
                }
            }

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
            if exitCode != 0,
               let index = sessions.firstIndex(where: { $0.id == sessionID }),
               sessions[index].agent != .antigravity,
               sessions[index].agentSessionID != nil,
               !sessionResumeRetried.contains(sessionID),
               let start = sessionResumeStarts[sessionID],
               Date().timeIntervalSince(start) < 4.0 {
                // Self-heal: retry once with fresh context
                sessionResumeRetried.insert(sessionID)
                sessionResumeStarts.removeValue(forKey: sessionID)
                sessions[index].agentSessionID = nil
                try? repository.save(mergingLiveScrollback(sessions[index]))
                processManager.killServerSideSession(sessionID: sessionID)
                do {
                    try processManager.start(session: sessions[index], deliverGoal: false)
                    sessions[index] = statusMachine.transition(sessions[index], to: .working)
                    try repository.save(mergingLiveScrollback(sessions[index]))
                    scheduleTitleSync(forSessionID: sessionID)
                    lastOperationError = "Previous conversation could not be restored — starting a fresh context."
                    return
                } catch {
                    // fall through
                }
            }
            sessionResumeStarts.removeValue(forKey: sessionID)
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
