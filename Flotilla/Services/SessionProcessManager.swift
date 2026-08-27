import Foundation
import os
import AgentKit
import SessionKit
import ProcessKit
import SettingsKit
import HooksKit
import GitKit

/// Owns the live `PTYProcessProtocol` for every session that has been
/// started, keyed by session id. Sessions keep running here across sidebar
/// selection changes — Phase 7's terminal view just attaches to whatever
/// is already running rather than owning process lifecycle itself.
@MainActor
final class SessionProcessManager {
    private var processes: [UUID: PTYProcessProtocol] = [:]
    private var activeSessions: [UUID: Session] = [:]
    private var tmuxWrappedSessions: [UUID: URL] = [:]
    private var reattachTimestamps: [UUID: [Date]] = [:]
    private var verifyResizeTasks: [UUID: Task<Void, Never>] = [:]
    private var goalDeliveryTasks: [UUID: Task<Void, Never>] = [:]
    private let gitService: any GitServiceProtocol
    /// Repos the attribution hook has already been offered this launch, so a
    /// burst of session starts doesn't re-stat the same hooks directory.
    private var trailerHookInstalledRepos: Set<URL> = []
    private var hasConfiguredGlobalOptions = false
    private let locator: ExecutableLocating
    private let processFactory: any PTYProcessCreating
    private let providers: AgentProviderRegistry
    private let settingsProvider: () -> AppSettings
    private let tmuxTerminator: any TmuxSessionTerminating
    private let tmuxGoalDeliverer: any TmuxGoalDelivering
    private let tmuxServerProbe: any TmuxServerProbing
    private let tmuxClientProbe: any TmuxClientProbing
    private let conversationOwnershipChecker: any AgentConversationOwnershipChecking
    private let hookConfigurationWriter: any HookConfiguring
    private let hookSupportDirectory: URL
    private var intentionallyTerminating = Set<UUID>()
    private var tmuxProbeCache: (usable: Bool, probedAt: Date)?
    private static let tmuxProbeCacheLifetime: TimeInterval = 5
    var eventHandler: ((SessionProcessEvent) -> Void)?

    enum SessionProcessEvent: Equatable {
        case terminated(sessionID: UUID, exitCode: Int32)
        /// The tmux server did not answer clients, so the session was
        /// launched directly in the PTY instead — losing quit/relaunch
        /// persistence for that session, but keeping it usable at all.
        case launchedWithoutTmux(sessionID: UUID)
    }

    enum LaunchError: LocalizedError, Equatable {
        case executableNotFound(agent: AgentKind, binary: String, configuredPath: String)
        case conversationAlreadyActive(agent: AgentKind, conversationID: String)
        case failedToStart(agent: AgentKind, message: String)

        var errorDescription: String? {
            switch self {
            case let .executableNotFound(agent, binary, configuredPath):
                if configuredPath.isEmpty {
                    return "\(agent.displayName) was not found. Install ‘\(binary)’ or choose its executable in Settings."
                }
                return "\(agent.displayName) is not executable at \(configuredPath). Choose a valid binary in Settings."
            case let .conversationAlreadyActive(agent, _):
                return "\(agent.displayName) conversation is already open in another CLI. Close that CLI, then reopen this Flotilla session; use Restart Session only to begin a fresh conversation."
            case let .failedToStart(agent, message):
                return "\(agent.displayName) could not start: \(message)"
            }
        }
    }

    init(
        locator: ExecutableLocating = PATHExecutableLocator(),
        processFactory: any PTYProcessCreating = SystemPTYProcessFactory(),
        providers: AgentProviderRegistry = AgentProviderRegistry(),
        settingsProvider: @escaping () -> AppSettings = { AppSettings() },
        tmuxTerminator: any TmuxSessionTerminating = ProcessTmuxSessionTerminator(),
        tmuxGoalDeliverer: any TmuxGoalDelivering = ProcessTmuxGoalDeliverer(),
        tmuxServerProbe: any TmuxServerProbing = ProcessTmuxServerProbe(),
        tmuxClientProbe: any TmuxClientProbing = ProcessTmuxClientProbe(),
        conversationOwnershipChecker: any AgentConversationOwnershipChecking = ProcessAgentConversationOwnershipChecker(),
        hookConfigurationWriter: any HookConfiguring = HookConfigurationWriter(),
        hookSupportDirectory: URL = TmuxSessionWrapping.defaultSupportDirectory(),
        gitService: any GitServiceProtocol = GitService()
    ) {
        self.locator = locator
        self.gitService = gitService
        self.processFactory = processFactory
        self.providers = providers
        self.settingsProvider = settingsProvider
        self.tmuxTerminator = tmuxTerminator
        self.tmuxGoalDeliverer = tmuxGoalDeliverer
        self.tmuxServerProbe = tmuxServerProbe
        self.tmuxClientProbe = tmuxClientProbe
        self.conversationOwnershipChecker = conversationOwnershipChecker
        self.hookConfigurationWriter = hookConfigurationWriter
        self.hookSupportDirectory = hookSupportDirectory
    }

    func process(for sessionID: UUID) -> PTYProcessProtocol? {
        processes[sessionID]
    }

    /// Destroys the server-side tmux session for `sessionID` if one exists,
    /// regardless of whether THIS manager instance knows about it. Needed
    /// after an app relaunch: the manager starts empty, so `terminate()`'s
    /// bookkeeping would miss sessions tmux kept alive — and a restart's
    /// `new-session -A` would then just reattach to the old session instead
    /// of launching a fresh agent.
    func killServerSideSession(sessionID: UUID) {
        guard let tmuxExecutable = locator.locate("tmux") else { return }
        goalDeliveryTasks[sessionID]?.cancel()
        goalDeliveryTasks[sessionID] = nil
        tmuxWrappedSessions[sessionID] = nil
        latestExpectedSizes[sessionID] = nil
        tmuxTerminator.killSession(
            named: TmuxSessionWrapping.sessionName(for: sessionID),
            tmuxExecutable: tmuxExecutable
        )
    }

    /// Reconciles active tmux sessions on the Flotilla socket against known valid session IDs.
    /// Any background session named `flotilla-<UUID>` not found in `knownSessionIDs` is reaped.
    func reapOrphanTmuxSessions(knownSessionIDs: Set<UUID>) {
        guard let tmuxExecutable = locator.locate("tmux") else { return }
        let activeSessions = tmuxTerminator.listSessions(tmuxExecutable: tmuxExecutable)
        let prefix = "flotilla-"
        for name in activeSessions where name.hasPrefix(prefix) {
            let uuidString = String(name.dropFirst(prefix.count))
            if let uuid = UUID(uuidString: uuidString), !knownSessionIDs.contains(uuid) {
                tmuxTerminator.killSession(named: name, tmuxExecutable: tmuxExecutable)
            }
        }
    }

    @discardableResult
    func start(
        session: Session,
        deliverGoal: Bool = true,
        selfReportInstructions: String? = nil,
        selfReportDescriptorPath: URL? = nil
    ) throws -> PTYProcessProtocol {
        // A restart is in flight: the registered process was told to die but
        // its exit callback has not landed yet. Returning it would hand the
        // caller a dying process whose eventual exit clears the session's
        // process entry — the "restart does not work" symptom. Start fresh.
        let restartInFlight = intentionallyTerminating.contains(session.id)
        if let existing = processes[session.id], existing.isRunning, !restartInFlight {
            return existing
        }

        intentionallyTerminating.remove(session.id)

        let descriptor = AgentCatalog.descriptor(for: session.agent)
        let resumeIntent: ResumeIntent
        if let agentSessionID = session.agentSessionID, !agentSessionID.isEmpty {
            resumeIntent = .resume(agentSessionID)
        } else if case .assignable = descriptor.resume {
            resumeIntent = .freshWithAssignedIdentity(session.id.uuidString)
        } else {
            resumeIntent = .none
        }

        // If our tmux pane still exists, `new-session -A` only reattaches to
        // it — it does not start the command after `--`, so no second agent
        // process is created. Native resume is only needed after that pane is
        // gone. Antigravity explicitly permits just one CLI per conversation,
        // therefore refuse to create a competing `agy --conversation` process.
        let tmuxExecutable = usableTmuxExecutable(for: session.id)
        let hasLiveTmuxSession = tmuxExecutable.map {
            tmuxTerminator.listSessions(tmuxExecutable: $0)
                .contains(TmuxSessionWrapping.sessionName(for: session.id))
        } ?? false
        if session.agent == .antigravity,
           case let .resume(conversationID) = resumeIntent,
           !hasLiveTmuxSession,
           conversationOwnershipChecker.isConversationActive(agent: session.agent, conversationID: conversationID) {
            throw LaunchError.conversationAlreadyActive(agent: session.agent, conversationID: conversationID)
        }

        let effectiveDeliverGoal: Bool
        if case .resume = resumeIntent {
            effectiveDeliverGoal = false
        } else {
            effectiveDeliverGoal = deliverGoal
        }

        // Best-effort: a broken/read-only project directory must not block
        // launch. When this succeeds, HookCoordinator's HookEventReceiver
        // picks up structured status from the same session ID; when it
        // doesn't (or the agent kind isn't hook-capable), status still
        // comes from TerminalScreenHeuristic as before.
        let hooksConfigured = hookConfigurationWriter.configureHooks(
            for: session.agent,
            sessionID: session.id,
            workingDirectory: session.workingDirectory,
            supportDirectory: hookSupportDirectory
        )

        let provider = providers.provider(for: session.agent)
        let settings = settingsProvider()

        // Scoped to the agent's own process tree, which is what makes the
        // attribution hook safe to leave installed: without these variables it
        // no-ops, so the user's own commits are never stamped.
        var baseEnvironment = ProcessInfo.processInfo.environment
        if hooksConfigured {
            baseEnvironment[HookConfigurationWriter.eventFileEnvironmentKey] =
                HookConfigurationWriter.eventFilePath(
                    for: session.id,
                    supportDirectory: hookSupportDirectory
                ).path
        }
        if settings.git.stampAgentTrailer,
           let attributionEnvironment = agentAttributionEnvironment(for: session, base: baseEnvironment) {
            baseEnvironment = attributionEnvironment
        }
        if let selfReportDescriptorPath {
            baseEnvironment["FLOTILLA_SELF_REPORT_PATH"] = selfReportDescriptorPath.path
        }

        // When self-report instructions are provided and the goal is being
        // delivered (first launch, not resume), prepend them so the agent
        // reads the setup block before the user's actual objective.
        let effectiveGoal: String?
        if effectiveDeliverGoal {
            if let selfReportInstructions, !selfReportInstructions.isEmpty {
                effectiveGoal = selfReportInstructions + session.goal
            } else {
                effectiveGoal = session.goal
            }
        } else {
            effectiveGoal = nil
        }

        var plan = provider.launchPlan(
            goal: effectiveGoal,
            model: session.model,
            effort: session.effort,
            resumeIntent: resumeIntent,
            settings: settings,
            baseEnvironment: baseEnvironment
        )
        // Hook wiring travels with the process as launch arguments (see
        // HookConfigurationWriter's doc comment for why) rather than
        // through a file other sessions could also read — only added once
        // configureHooks has actually prepared this session's event file.
        if hooksConfigured {
            plan.arguments += hookConfigurationWriter.launchArguments(
                for: session.agent,
                supportDirectory: hookSupportDirectory
            )
        }
        guard let resolvedExecutable = resolveExecutable(plan: plan) else {
            throw LaunchError.executableNotFound(
                agent: session.agent,
                binary: plan.binaryName,
                configuredPath: plan.configuredPath
            )
        }
        tmuxWrappedSessions[session.id] = tmuxExecutable
        // Covers an already-running server; the `-f` config passed to
        // `new-session` below covers the cold-socket case this cannot.
        var tmuxConfigurationFile: URL?
        if let tmuxExecutable {
            tmuxConfigurationFile = TmuxSessionWrapping.writeConfigurationFile()
            if !hasConfiguredGlobalOptions {
                hasConfiguredGlobalOptions = true
                Task.detached(priority: .utility) {
                    for option in TmuxSessionWrapping.globalOptions {
                        let setOptionProcess = Process()
                        setOptionProcess.executableURL = tmuxExecutable
                        setOptionProcess.arguments = TmuxSessionWrapping.socketArguments()
                            + ["set-option", "-g"] + option
                        setOptionProcess.standardOutput = FileHandle.nullDevice
                        setOptionProcess.standardError = FileHandle.nullDevice
                        if (try? setOptionProcess.run()) != nil {
                            setOptionProcess.waitUntilExit()
                        }
                    }
                }
            }
        }

        let launch = TmuxSessionWrapping.wrap(
            agentExecutable: resolvedExecutable,
            arguments: plan.arguments,
            environment: plan.environment,
            workingDirectory: session.workingDirectory,
            sessionID: session.id,
            tmuxExecutable: tmuxExecutable,
            configurationFile: tmuxConfigurationFile
        )

        let process = processFactory.makeProcess()
        // Standard initial terminal dimensions for background / unmounted launches.
        // `TerminalController.sizeChanged` updates this to measured geometry upon mount.
        let size = PTYSize(cols: 100, rows: 30)
        process.terminationHandler = { [weak self, weak process] exitCode in
            Task { @MainActor [weak self] in
                guard let self, let process else { return }
                if self.processes[session.id] === process {
                    self.processes[session.id] = nil
                    if self.intentionallyTerminating.remove(session.id) == nil {
                        self.eventHandler?(.terminated(sessionID: session.id, exitCode: exitCode))
                    }
                } else {
                    self.intentionallyTerminating.remove(session.id)
                }
            }
        }

        do {
            try process.start(
                executable: launch.executable,
                arguments: launch.arguments,
                environment: launch.environment,
                workingDirectory: session.workingDirectory,
                initialSize: size
            )
        } catch {
            throw LaunchError.failedToStart(agent: session.agent, message: error.localizedDescription)
        }

        processes[session.id] = process
        activeSessions[session.id] = session
        goalDeliveryTasks[session.id]?.cancel()
        goalDeliveryTasks[session.id] = nil
        if plan.initialInput != nil {
            if let tmuxExecutable {
                // A raw PTY write only ever gets the goal typed, not
                // submitted (see TmuxGoalDelivering's doc comment) — tmux
                // send-keys is the mechanism confirmed to actually work.
                let deliverer = tmuxGoalDeliverer
                let trimmedGoal = (effectiveGoal ?? session.goal).trimmingCharacters(in: .whitespacesAndNewlines)
                let sessionName = TmuxSessionWrapping.sessionName(for: session.id)
                goalDeliveryTasks[session.id] = Task.detached(priority: .userInitiated) {
                    guard !Task.isCancelled else { return }
                    deliverer.deliverGoal(trimmedGoal, toSessionNamed: sessionName, tmuxExecutable: tmuxExecutable)
                }
            } else if let initialInput = plan.initialInput {
                process.send(input: initialInput)
            }
        }
        return process
    }

    func isTmuxWrapped(sessionID: UUID) -> Bool {
        tmuxWrappedSessions[sessionID] != nil
    }

    func refreshTmuxClient(for sessionID: UUID) {
        guard let tmuxExecutable = tmuxWrappedSessions[sessionID] else { return }
        let sessionName = TmuxSessionWrapping.sessionName(for: sessionID)
        let probe = tmuxClientProbe
        Task.detached(priority: .utility) {
            probe.refreshClient(sessionNamed: sessionName, tmuxExecutable: tmuxExecutable)
        }
    }

    /// Replaces only the outer PTY process (the tmux client), detaching and
    /// reattaching to the existing server-side tmux session without killing the
    /// agent running inside it. Used to recover from a deaf or desynced client.
    @discardableResult
    func reattach(session: Session) throws -> PTYProcessProtocol {
        if let existing = processes[session.id], existing.isRunning {
            intentionallyTerminating.insert(session.id)
            existing.terminate()
            processes[session.id] = nil
        }
        return try start(session: session, deliverGoal: false)
    }

    @discardableResult
    func reattach(sessionID: UUID) throws -> PTYProcessProtocol? {
        guard let session = activeSessions[sessionID] else { return nil }
        return try reattach(session: session)
    }

    private var latestExpectedSizes: [UUID: PTYSize] = [:]

    /// Verifies whether tmux registered the resize that was sent to the outer PTY.
    /// If tmux's client size does not match after debounce, non-destructively
    /// reattaches the client up to a rate limit of 2 attempts per minute per session.
    func verifyAndRecoverResize(
        sessionID: UUID,
        expectedSize: PTYSize,
        onRecoveryFailure: (@MainActor (String) -> Void)? = nil
    ) {
        guard let tmuxExecutable = tmuxWrappedSessions[sessionID] else { return }
        let sessionName = TmuxSessionWrapping.sessionName(for: sessionID)
        let probe = tmuxClientProbe
        latestExpectedSizes[sessionID] = expectedSize

        verifyResizeTasks[sessionID]?.cancel()
        verifyResizeTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.latestExpectedSizes[sessionID] == expectedSize else { return }

            let reportedSize = await Task.detached(priority: .utility) {
                probe.clientSize(sessionNamed: sessionName, tmuxExecutable: tmuxExecutable)
            }.value

            guard !Task.isCancelled, self.latestExpectedSizes[sessionID] == expectedSize else { return }

            if let reportedSize {
                Logger(subsystem: "com.niclassslua.flotilla", category: "TerminalResize").notice(
                    "Resize check for \(sessionID): expected \(expectedSize.cols)x\(expectedSize.rows), tmux reported \(reportedSize.cols)x\(reportedSize.rows)"
                )
                if reportedSize.cols != expectedSize.cols || reportedSize.rows != expectedSize.rows {
                    Logger(subsystem: "com.niclassslua.flotilla", category: "TerminalResize").error(
                        "Resize mismatch for \(sessionID): expected \(expectedSize.cols)x\(expectedSize.rows), tmux reported \(reportedSize.cols)x\(reportedSize.rows) — triggering reattach recovery"
                    )
                    await MainActor.run {
                        self.handleResizeMismatch(
                            sessionID: sessionID,
                            expectedSize: expectedSize,
                            onRecoveryFailure: onRecoveryFailure
                        )
                    }
                }
            }
        }
    }

    @MainActor
    private func handleResizeMismatch(
        sessionID: UUID,
        expectedSize: PTYSize,
        onRecoveryFailure: (@MainActor (String) -> Void)?
    ) {
        let now = Date()
        let window = now.addingTimeInterval(-60)
        var timestamps = (reattachTimestamps[sessionID] ?? []).filter { $0 > window }
        if timestamps.count >= 2 {
            let errorMsg = "Terminal resize recovery limit reached (2 attempts in 60s) for session \(sessionID)"
            Logger(subsystem: "com.niclassslua.flotilla", category: "TerminalResize").error("\(errorMsg)")
            onRecoveryFailure?(errorMsg)
            return
        }

        timestamps.append(now)
        reattachTimestamps[sessionID] = timestamps

        do {
            if let session = activeSessions[sessionID] {
                Logger(subsystem: "com.niclassslua.flotilla", category: "TerminalResize").notice(
                    "Reattaching session \(sessionID) due to resize mismatch"
                )
                try reattach(session: session)
            }
        } catch {
            let msg = "Failed to reattach mis-sized session \(sessionID): \(error.localizedDescription)"
            Logger(subsystem: "com.niclassslua.flotilla", category: "TerminalResize").error("\(msg)")
            onRecoveryFailure?(msg)
        }
    }

    private func resolveExecutable(plan: AgentLaunchPlan) -> URL? {
        if !plan.configuredPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: plan.configuredPath) {
            return URL(fileURLWithPath: plan.configuredPath)
        }
        return locator.locate(plan.binaryName)
    }

    /// Returns the tmux executable to wrap launches with, or `nil` when the
    /// server is provably not answering clients. A wedged server (accepts
    /// the connection, then drops it — "server exited unexpectedly") makes
    /// every `new-session -A` exit 1 instantly, which surfaced as sessions
    /// that crash on launch and can never be restarted. The verdict is
    /// cached briefly so restoring several sessions at launch costs one
    /// probe, not one subprocess per session.
    private func usableTmuxExecutable(for sessionID: UUID) -> URL? {
        guard let executable = locator.locate("tmux") else { return nil }
        if let cache = tmuxProbeCache,
           Date().timeIntervalSince(cache.probedAt) < Self.tmuxProbeCacheLifetime {
            return cache.usable ? executable : nil
        }
        let usable = tmuxServerProbe.serverIsUsable(tmuxExecutable: executable)
        tmuxProbeCache = (usable, Date())
        if !usable {
            eventHandler?(.launchedWithoutTmux(sessionID: sessionID))
        }
        return usable ? executable : nil
    }

    /// Kills the underlying tmux session too, not just the outer attached
    /// client — a plain `process.terminate()` would only detach the client
    /// and leave the tmux session (and the agent inside it) running forever.
    /// Caller-initiated terminations are exactly the cases that must not
    /// survive: restart (a fresh agent is wanted) and delete (full cleanup).
    /// App quit never calls this, so tmux-backed sessions still survive a
    /// relaunch by design.
    func terminate(sessionID: UUID) {
        activeSessions[sessionID] = nil
        verifyResizeTasks[sessionID]?.cancel()
        verifyResizeTasks[sessionID] = nil
        goalDeliveryTasks[sessionID]?.cancel()
        goalDeliveryTasks[sessionID] = nil
        reattachTimestamps[sessionID] = nil

        if let process = processes[sessionID], process.isRunning {
            intentionallyTerminating.insert(sessionID)
            process.terminate()
        } else {
            intentionallyTerminating.remove(sessionID)
        }
        // The tmux session outlives its client, and its agent keeps running
        // detached unless the server-side session is killed explicitly.
        // This must complete before a restart's `new-session -A` runs, or
        // the two could race (kill-session landing after the fresh session
        // was created, killing the new agent too).
        if let tmuxExecutable = tmuxWrappedSessions[sessionID] {
            tmuxWrappedSessions[sessionID] = nil
            tmuxTerminator.killSession(
                named: TmuxSessionWrapping.sessionName(for: sessionID),
                tmuxExecutable: tmuxExecutable
            )
        }
        // Do NOT remove processes[sessionID] here — the process's
        // terminationHandler will clear it once the exit callback fires.
    }

    /// Points the agent's git at Flotilla's own hooks directory so its commits
    /// get an attribution trailer, without touching the repository or the
    /// user's global git configuration.
    ///
    /// Returns `nil` when anything can't be resolved — attribution is a
    /// convenience and must never be a reason a session fails to start.
    private func agentAttributionEnvironment(
        for session: Session,
        base: [String: String]
    ) -> [String: String]? {
        let hooksDirectory = TmuxSessionWrapping.defaultSupportDirectory()
            .appendingPathComponent("githooks", isDirectory: true)

        do {
            try AgentTrailerHooks().prepare(directory: hooksDirectory)
        } catch {
            Logger(subsystem: "com.niclassslua.flotilla", category: "GitAttribution")
                .notice("Could not prepare the agent hooks directory: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // The hooks the repo would otherwise have run are resolved by the
        // shims themselves at commit time, which keeps this synchronous and
        // stays correct if the user's git config changes mid-session.
        return AgentTrailerHooks.environment(
            base: base,
            agentRawValue: session.agent.rawValue,
            sessionID: session.id.uuidString,
            flotillaHooksDirectory: hooksDirectory,
            originalHooksDirectory: nil
        )
    }

}
