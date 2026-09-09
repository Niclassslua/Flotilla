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
    let kanbanStore: KanbanStore
    var kanbanBoards: [KanbanBoard] { kanbanStore.kanbanBoards }
    var selectedSessionID: UUID?
    var selectedProjectID: UUID?
    var selectedKanbanBoardID: UUID? {
        get { kanbanStore.selectedKanbanBoardID }
        set { kanbanStore.selectedKanbanBoardID = newValue }
    }
    var lastCreationError: String?
    var lastOperationError: String?
    /// Called once per clean process exit (never on `.crashed`), after the
    /// session's status has landed on `.readyForReview` — the app layer
    /// decides whether/how to notify from here, so this stays a plain
    /// closure rather than pulling a notification dependency into AppStore.
    var onSessionFinished: ((Session) -> Void)?
    /// Fires when a session's agent changes under it, so status observation can
    /// be rebuilt against the new agent. Hook event schemas differ per agent and
    /// a `HookEventReceiver` binds to one for its lifetime, so a receiver that
    /// outlives the change parses the new agent's output against the old
    /// agent's format. Same plain-closure rationale as `onSessionFinished`.
    var onAgentChanged: ((UUID) -> Void)?

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
    private let scrollbackStore = SessionScrollbackStore()
    private let metadataMonitor: SessionMetadataMonitor
    private let handoffService: HandoffService
    /// Sessions whose handoff destination has not yet proved it can run.
    @ObservationIgnored
    private var handoffProbation: Set<UUID> = []
    @ObservationIgnored
    private var sessionResumeStarts: [UUID: Date] = [:]
    @ObservationIgnored
    private var sessionResumeRetried: Set<UUID> = []

    init(
        repository: SessionRepository,
        gitService: GitServiceProtocol,
        ghService: GhServiceProtocol? = nil,
        processManager: SessionProcessManager,
        worktreeBaseDirectoryProvider: @escaping () -> URL,
        settingsProvider: @escaping () -> AppSettings = { AppSettings() },
        metadataMonitor: SessionMetadataMonitor = SessionMetadataMonitor(),
        handoffService: HandoffService? = nil
    ) {
        self.metadataMonitor = metadataMonitor
        self.handoffService = handoffService ?? HandoffService(processManager: processManager)
        self.repository = repository
        self.kanbanStore = KanbanStore(repository: repository)
        self.gitService = gitService
        self.ghService = ghService
        self.diffStatStore = DiffStatStore(gitService: gitService)
        self.processManager = processManager
        self.worktreeBaseDirectoryProvider = worktreeBaseDirectoryProvider
        self.settingsProvider = settingsProvider
        processManager.eventHandler = { [weak self] event in
            self?.handleProcessEvent(event)
        }
        if reload() { restoreSessions() }
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

    @discardableResult
    func reload() -> Bool {
        do {
            let loaded = try repository.loadAll()
            projects = loaded.projects
            sessions = loaded.sessions
            scrollbackStore.seed(loaded.sessions)
        } catch {
            lastOperationError = "Session data could not be loaded: \(error.localizedDescription)"
            return false
        }
        return true
    }

    /// Launch-time recovery only. Refreshing saved data never starts processes.
    private func restoreSessions() {
        processManager.reapOrphanTmuxSessions(knownSessionIDs: Set(sessions.map(\.id)))

        // One-time migration: sessions created before the fix above have the
        // raw home directory persisted as their working directory. Redirect
        // them to the safe scratch directory before their process restarts,
        // rather than only fixing newly-created sessions.
        let rawHomeDirectory = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        for index in sessions.indices where sessions[index].workingDirectory.standardizedFileURL == rawHomeDirectory {
            sessions[index].workingDirectory = Self.generalSessionWorkingDirectory()
            try? repository.save(mergingLiveScrollback(sessions[index]))
        }

        // A session with no status yet (never observed) is restarted like any
        // other live session; only a crashed one is left alone.
        for index in sessions.indices where sessions[index].status?.isTerminal != true {
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
                    sessions[index] = transition(sessions[index], to: .crashed, origin: .restoreFailed)
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
                sessions[index] = transition(sessions[index], to: .crashed, origin: .restoreFailed)
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
        try kanbanStore.create(board)
    }

    func loadKanbanBoards() {
        performBoardOperation { kanbanStore.load(projects: projects) }
    }

    var selectedKanbanBoard: KanbanBoard? { kanbanStore.selectedKanbanBoard }

    func selectKanbanBoard(_ boardID: UUID) { kanbanStore.selectKanbanBoard(boardID) }

    func selectKanbanBoard(forProject projectID: UUID?) {
        kanbanStore.selectKanbanBoard(forProject: projectID)
    }

    func saveKanbanBoard(_ board: KanbanBoard) {
        performBoardOperation { kanbanStore.save(board) }
    }

    func updateKanbanBoardColumnMode(_ mode: KanbanColumnMode) {
        performBoardOperation { kanbanStore.updateKanbanBoardColumnMode(mode) }
    }

    func updateKanbanCardOrder(_ cardOrder: [String: Int]) {
        performBoardOperation { kanbanStore.updateKanbanCardOrder(cardOrder) }
    }

    private func performBoardOperation(_ operation: () -> Void) {
        kanbanStore.lastOperationError = nil
        operation()
        if let error = kanbanStore.lastOperationError { lastOperationError = error }
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
        session = transition(session, to: status, origin: .boardMove)
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
        kanbanStore.getColumnsForBoard(board)
    }

    func getSessionsForColumn(_ column: KanbanColumn, board: KanbanBoard) -> [Session] {
        kanbanStore.getSessionsForColumn(column, board: board, sessions: sessions)
    }

    /// The live process backing a session, if one has been started.
    func process(for sessionID: UUID) -> PTYProcessProtocol? {
        processManager.process(for: sessionID)
    }
    // ... rest of the file

    /// Seeds the same permission-prompt state the observation pipeline would
    /// produce, then echoes the prompt into the mock terminal for UI
    /// automation. This is unavailable outside an explicit UI-testing launch
    /// and never touches production processes.
    func simulateWaitingPromptForUITesting(sessionTitle: String) {
        #if DEBUG
        let isUITesting = ProcessInfo.processInfo.environment["UI_TESTING"] == "1"
        #else
        let isUITesting = false
        #endif
        guard isUITesting,
              let session = sessions.first(where: { $0.title == sessionTitle }),
              let process = processManager.process(for: session.id) as? MockPTYProcess else { return }
        applyObservedStatus(
            .waitingForInput,
            waitingReason: .permission,
            origin: .uiTestFixture,
            toSessionID: session.id
        )
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
        sessions[index] = transition(sessions[index], to: .crashed, origin: .uiTestFixture)
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
        scrollbackStore.buffer(for: sessionID) ?? sessions.first(where: { $0.id == sessionID })?.terminalScrollback ?? Data()
    }

    /// Returns `session` with its `terminalScrollback` replaced by the live
    /// buffer, if any. Every `repository.save` of a session pulled from
    /// `sessions` must go through this — `sessions[index].terminalScrollback`
    /// is not kept current (see `SessionScrollbackStore`), so saving it unmerged
    /// would overwrite the persisted history with a stale, possibly empty,
    /// snapshot.
    private func mergingLiveScrollback(_ session: Session) -> Session {
        scrollbackStore.merging(session)
    }

    /// `SessionStatusMachine.transition` with a trace line attached, so every
    /// status a session takes — and every one it was asked to take and
    /// refused — is explained in the log by whatever caused it. Direct calls
    /// to the machine bypass the trace and should not exist in this type.
    private func transition(
        _ session: Session,
        to status: SessionStatus,
        origin: SessionStatusOrigin
    ) -> Session {
        let updated = statusMachine.transition(session, to: status)
        if updated.status == session.status {
            SessionStatusTrace.ignored(
                sessionID: session.id,
                title: session.title,
                current: session.status,
                currentReason: session.waitingReason,
                requested: status,
                origin: origin,
                detail: session.status == status
                    ? "already in that status"
                    : "SessionStatusMachine refused the transition"
            )
        } else {
            SessionStatusTrace.applied(
                sessionID: session.id,
                title: session.title,
                from: session.status,
                fromReason: session.waitingReason,
                to: status,
                toReason: updated.waitingReason,
                origin: origin
            )
        }
        return updated
    }

    func applyObservedStatus(
        _ status: SessionStatus,
        waitingReason: SessionWaitingReason? = nil,
        origin: SessionStatusOrigin = .unattributed,
        toSessionID sessionID: UUID
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let current = sessions[index]
        let resolvedWaitingReason = status == .waitingForInput
            ? (waitingReason ?? current.waitingReason)
            : nil
        // Observed status is a level, not an edge: the observer re-reports
        // `.working` for every chunk a streaming agent produces. Filtering
        // no-ops here keeps them out of the machine, which treats a
        // self-transition as illegal and logs each one.
        guard current.status != status || current.waitingReason != resolvedWaitingReason else { return }

        var updated: Session
        if current.status == status {
            updated = current
            updated.waitingReason = resolvedWaitingReason
            updated.lastActiveAt = Date()
        } else {
            updated = statusMachine.transition(current, to: status)
            guard updated.status != current.status else {
                SessionStatusTrace.ignored(
                    sessionID: current.id,
                    title: current.title,
                    current: current.status,
                    currentReason: current.waitingReason,
                    requested: status,
                    origin: origin,
                    detail: "SessionStatusMachine refused the transition"
                )
                return
            }
            updated.waitingReason = resolvedWaitingReason
        }
        SessionStatusTrace.applied(
            sessionID: current.id,
            title: current.title,
            from: current.status,
            fromReason: current.waitingReason,
            to: updated.status ?? status,
            toReason: updated.waitingReason,
            origin: origin
        )
        sessions[index] = updated
        do {
            try repository.save(mergingLiveScrollback(updated))
        } catch {
            lastOperationError = "Session status could not be saved: \(error.localizedDescription)"
        }
    }

    /// Asynchronously queries the active agent's native storage/API for an
    /// auto-generated session title and session ID, applying both if found.
    func syncAgentSessionMetadata(forSessionID sessionID: UUID) async {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        let generation = metadataMonitor.generation(for: sessionID)
        if let discovered = await metadataMonitor.discover(session) {
            guard metadataMonitor.isCurrent(generation, for: sessionID),
                  sessions.contains(where: { $0.id == sessionID }) else { return }
            // Pin the discovered native session ID before title guards.
            //
            // Never take one another session already holds: discovery for an
            // agent that records no working directory is an association by
            // launch time, and two sessions must not end up resuming the same
            // conversation — which would have them append to one history and
            // fork it.
            if let index = sessions.firstIndex(where: { $0.id == sessionID }),
               sessions[index].agentSessionID == nil || sessions[index].agentSessionID?.isEmpty == true,
               !sessions.contains(where: { $0.id != sessionID && $0.agentSessionID == discovered.id }) {
                sessions[index].agentSessionID = discovered.id
                try? repository.save(mergingLiveScrollback(sessions[index]))
            }

            // When our own setup-step title is in play, it's authoritative —
            // don't let the agent's native title (discovered on its own,
            // later, separate schedule) clobber it and reintroduce the
            // title/worktree mismatch this setting exists to prevent.
            guard !settingsProvider().sessionDefaults.agentManagedTitleEnabled else { return }

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

    func scheduleTitleSync(forSessionID sessionID: UUID) {
        metadataMonitor.startDiscovery(for: sessionID, isActive: { [weak self] in
            self?.isSessionActive(sessionID) ?? false
        }, refresh: { [weak self] in
            await self?.syncAgentSessionMetadata(forSessionID: sessionID)
        })
    }

    /// Whether a session is still in a state where its agent process is
    /// expected to be doing (or about to do) work — used to decide when a
    /// background poll loop should keep waiting versus give up.
    private func isSessionActive(_ sessionID: UUID) -> Bool {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return false }
        return session.status == .working
            || session.status == .waitingForInput
            || session.status == nil
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

    /// Keeps persisted worktree metadata aligned when the user checks out a
    /// different branch from the session Git sidebar. Main-checkout sessions
    /// deliberately have no `WorktreeInfo`; their current branch remains Git
    /// state rather than being duplicated in the session record.
    func updateSessionBranch(sessionID: UUID, branchName: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              var worktree = sessions[index].worktree,
              worktree.branchName != branchName else { return }
        worktree.branchName = branchName
        sessions[index].worktree = worktree
        do {
            try repository.save(mergingLiveScrollback(sessions[index]))
        } catch {
            lastOperationError = "Session branch could not be saved: \(error.localizedDescription)"
        }
    }

    // MARK: - Agent self-report

    private func monitorSelfReport(sessionID: UUID, descriptorPath: URL, wantsWorktree: Bool, projectFolder: URL?) {
        metadataMonitor.startSelfReport(
            for: sessionID, path: descriptorPath, wantsWorktree: wantsWorktree,
            exists: { [weak self] in self?.sessions.contains(where: { $0.id == sessionID }) ?? false },
            isActive: { [weak self] in self?.isSessionActive(sessionID) ?? false },
            fallback: { [weak self] in
                await self?.fallBackToAppManagedWorktree(sessionID: sessionID, projectFolder: projectFolder)
            },
            apply: { [weak self] descriptor, fallback in
                await self?.applySelfReport(descriptor, sessionID: sessionID, projectFolder: projectFolder, replacing: fallback)
            }
        )
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
            if let index = sessions.firstIndex(where: { $0.id == sessionID }),
               sessions[index].workingDirectory == fallbackWorktree.worktreePath {
                processManager.terminate(sessionID: sessionID)
            }
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

        guard !Task.isCancelled, let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }

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
    /// the configured fallback timeout. Returns the worktree it created, so the
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
            guard !Task.isCancelled, let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
                try? await gitService.removeWorktree(at: worktree.path, in: basePath, branch: worktree.branch, deleteBranch: true)
                return nil
            }
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
        scrollbackStore.append(data, to: sessionID) { [weak self] in
            guard let self else { return }
            guard let index = self.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
            let snapshot = self.mergingLiveScrollback(self.sessions[index])
            let repository = self.repository
            // Off the main actor: `AppStore` is `@MainActor`, so an unstructured
            // `Task` here inherits that isolation, and `save` is a synchronous
            // fsyncing GRDB write. That put a 256 KB blob write on the main
            // thread every two seconds for every session producing output.
            let failure: String? = await Task.detached(priority: .utility) {
                do {
                    try repository.save(snapshot)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard !Task.isCancelled, let failure else { return }
            self.lastOperationError = "Terminal history could not be saved: \(failure)"
        }
    }

    /// Immediately flushes all debounced live scrollback buffers to the persistent
    /// repository, cancelling in-flight debounce timers. Called before app termination
    /// to guarantee zero terminal history loss on Cmd+Q.
    func shutdown() {
        metadataMonitor.cancelAll()
        flushLiveScrollback()
    }

    func flushLiveScrollback() {
        scrollbackStore.cancelPendingSaves()
        let pending = sessions.filter { scrollbackStore.buffer(for: $0.id) != nil }
            .map(mergingLiveScrollback)
        try? repository.save(pending)
    }

    func restartSession(sessionID: UUID) {
        metadataMonitor.cancel(sessionID)
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
            let updated = transition(sessions[index], to: .working, origin: .restart)
            sessions[index] = updated
            try repository.save(mergingLiveScrollback(updated))
            scheduleTitleSync(forSessionID: sessionID)
        } catch {
            lastOperationError = error.localizedDescription
        }
    }

    // MARK: - Handoff

    /// Agents this session can be moved to with its conversation intact.
    ///
    /// Empty when no codec can write the destination — which is how Antigravity
    /// stays out of the picker without anyone hardcoding the rule — and while a
    /// move is already in flight.
    func handoffTargets(for session: Session) -> [AgentKind] {
        handoffService.canHandOff(session) ? handoffService.targets(for: session) : []
    }

    /// Moves a session to another agent, carrying its conversation across.
    ///
    /// Distinct from `moveSessionToAgent(sessionID:agent:)`, which changes the
    /// agent and deliberately starts a *fresh* conversation.
    func handoffSession(sessionID: UUID, to target: AgentKind) async {
        // Deliberately does *not* cancel this session's metadata monitoring the
        // way `restartSession` does. That tears down the self-report descriptor
        // task, and when agent-managed titles are on it is the only route a
        // session has to a title — `syncAgentSessionMetadata` returns early in
        // that mode. Cancelling here left a session stuck on its provisional
        // name forever, with nothing to restart the wait, and did so even when
        // the handoff went on to fail.
        //
        // Nothing needs cancelling: a handoff keeps the conversation, so a
        // pending title is still this session's title, and discovery cannot
        // clobber the new agent's id because it only pins when none is set.
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        lastOperationError = nil
        let source = sessions[index].agent

        do {
            let plan = try handoffService.plan(for: sessions[index], to: target)
            let moved = try await handoffService.perform(plan)
            handoffProbation.insert(sessionID)
            sessions[index] = transition(moved, to: .working, origin: .handoff(from: source, to: target))
            try repository.save(mergingLiveScrollback(sessions[index]))
            onAgentChanged?(sessionID)
            scheduleHandoffSettlement(sessionID: sessionID)
            scheduleTitleSync(forSessionID: sessionID)
        } catch {
            lastOperationError = error.localizedDescription
        }
    }

    /// The source transcript is kept until the destination has stayed alive
    /// long enough to have actually read it.
    private func scheduleHandoffSettlement(sessionID: UUID) {
        let window = handoffService.probationWindow
        Task { [weak self] in
            try? await Task.sleep(for: window)
            self?.settleHandoff(sessionID: sessionID)
        }
    }

    private func settleHandoff(sessionID: UUID) {
        guard handoffProbation.remove(sessionID) != nil,
              let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let settled = handoffService.finalize(sessions[index])
        sessions[index] = settled
        try? repository.save(mergingLiveScrollback(settled))
    }

    /// A destination that died inside its probation window goes back to the
    /// agent it came from, onto the transcript that was never deleted.
    ///
    /// This must run *before* the generic resume self-heal in
    /// `handleProcessEvent`: that path clears `agentSessionID` and relaunches
    /// with a blank context, which after a handoff would throw away the very
    /// history the move existed to preserve.
    private func handleHandoffTermination(sessionID: UUID, exitCode: Int32) async {
        handoffProbation.remove(sessionID)
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }

        guard exitCode != 0 else {
            // A clean exit is a session that finished, not a move that failed.
            let settled = handoffService.finalize(sessions[index])
            sessions[index] = settled
            try? repository.save(mergingLiveScrollback(settled))
            applyObservedStatus(.readyForReview, origin: .processExit(code: exitCode), toSessionID: sessionID)
            return
        }

        let attempted = sessions[index].agent
        do {
            let restored = try await handoffService.rollback(sessions[index])
            sessions[index] = transition(restored, to: .working, origin: .handoffRollback)
            try repository.save(mergingLiveScrollback(sessions[index]))
            onAgentChanged?(sessionID)
            lastOperationError = "\(attempted.displayName) did not start, so the session was returned to \(restored.agent.displayName) with its conversation intact."
        } catch {
            lastOperationError = "The handoff failed and could not be undone: \(error.localizedDescription)"
            applyObservedStatus(.crashed, origin: .processExit(code: exitCode), toSessionID: sessionID)
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
        metadataMonitor.cancel(sessionID)

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

        scrollbackStore.remove(sessionID)

        if selectedSessionID == sessionID {
            selectedSessionID = nil
        }
        sessions.removeAll { $0.id == sessionID }

        if let worktreeCleanupWarning {
            lastOperationError = worktreeCleanupWarning
        }
    }

    /// Removes a worktree from a project checkout. When a session is bound to
    /// that directory the session goes with it, so no session record is left
    /// pointing at a path that no longer exists. Failures surface through
    /// `lastOperationError` instead of throwing: every caller is a menu item.
    func deleteWorktree(
        at path: URL,
        in repoPath: URL,
        branch: String,
        deleteBranch: Bool
    ) async {
        lastOperationError = nil

        if let session = sessions.first(where: {
            $0.worktree?.worktreePath.standardizedFileURL == path.standardizedFileURL
        }) {
            await deleteSession(sessionID: session.id, deleteWorktree: true, deleteBranch: deleteBranch)
            return
        }

        do {
            try await gitService.removeWorktree(
                at: path,
                in: repoPath,
                branch: branch,
                deleteBranch: deleteBranch
            )
        } catch {
            lastOperationError = "The worktree could not be removed: \(error.localizedDescription)"
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
        fetchBeforeCreatingWorktree: Bool = false,
        selectAfterCreating: Bool = true
    ) async -> UUID? {
        lastCreationError = nil
        var createdWorktree: WorktreeInfo?
        let settings = settingsProvider()
        let agentDescriptor = AgentCatalog.descriptor(for: agent)

        // Determine whether agent-managed features should activate.
        // Title generation applies uniformly regardless of whether the agent
        // has its own native title feature (Claude Code, Antigravity): our
        // setup-step title and its native one are picked at different points
        // in the run and can diverge, so only one is ever allowed to win —
        // whichever the `agentManagedTitleEnabled` setting selects. See
        // `syncAgentSessionMetadata`, which defers to this same setting
        // before letting a native title overwrite ours.
        let wantsAgentWorktree = checkoutMode == .newWorktree
            && projectFolder != nil
            && settings.git.worktreeNamingSource == .agentManaged
        let wantsAgentTitle = settings.sessionDefaults.agentManagedTitleEnabled

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
                worktree: worktreeInfo
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
            session = transition(session, to: .working, origin: .launch)
            do {
                try repository.save(session)
            } catch {
                processManager.terminate(sessionID: session.id)
                throw error
            }

            reload()
            // "Launch & Stay Here" passes `selectAfterCreating: false` so the
            // fleet/home view it was launched from stays put. Selecting here
            // unconditionally used to drag the detail column onto the new
            // session regardless of which launch button was pressed.
            if selectAfterCreating {
                selectedSessionID = session.id
            }
            scheduleTitleSync(forSessionID: session.id)

            // Kick off background polling for the agent's self-report
            // descriptor when either agent-managed feature is active.
            if let selfReportDescriptorPath, (wantsAgentWorktree || wantsAgentTitle) {
                monitorSelfReport(
                    sessionID: sessionID,
                    descriptorPath: selfReportDescriptorPath,
                    wantsWorktree: wantsAgentWorktree,
                    projectFolder: projectFolder
                )
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
            if handoffProbation.contains(sessionID) {
                Task { await handleHandoffTermination(sessionID: sessionID, exitCode: exitCode) }
                return
            }
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
                    sessions[index] = transition(sessions[index], to: .working, origin: .resumeRetry)
                    try repository.save(mergingLiveScrollback(sessions[index]))
                    scheduleTitleSync(forSessionID: sessionID)
                    lastOperationError = "Previous conversation could not be restored — starting a fresh context."
                    return
                } catch {
                    // fall through
                }
            }
            sessionResumeStarts.removeValue(forKey: sessionID)
            applyObservedStatus(
                exitCode == 0 ? .readyForReview : .crashed,
                origin: .processExit(code: exitCode),
                toSessionID: sessionID
            )
            if exitCode == 0, let session = sessions.first(where: { $0.id == sessionID }) {
                // A clean exit is still a "session finished" event for the
                // notification layer, even though the status now lands on
                // `readyForReview` alongside a quiet end-of-turn.
                onSessionFinished?(session)
            }
        case .launchedWithoutTmux:
            lastOperationError = "tmux is running but not answering clients, so the session was started without it. It will work normally, but will not survive quitting Flotilla."
        }
    }
}

private extension SessionStatus {
    var isTerminal: Bool {
        self == .crashed
    }
}
