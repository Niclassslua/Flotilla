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
    /// In-flight tmux send-keys (initial goal or `deliverMessage`). Stored as
    /// the detached task itself so `cancel()` reaches the deliverer.
    private var goalDeliveryTasks: [UUID: Task<Void, Error>] = [:]
    private let gitService: any GitServiceProtocol
    private var hasConfiguredGlobalOptions = false
    private let locator: ExecutableLocating
    private let processFactory: any PTYProcessCreating
    private let settingsProvider: () -> AppSettings
    private let environmentProvider: () -> [String: String]
    private let tmuxTerminator: any TmuxSessionTerminating
    private let tmuxGoalDeliverer: any TmuxGoalDelivering
    private let tmuxServerProbe: any TmuxServerProbing
    private let tmuxClientProbe: any TmuxClientProbing
    private let tmuxPaneProbe: any TmuxPaneProbing
    private let conversationOwnershipChecker: any AgentConversationOwnershipChecking
    private let hookConfigurationWriter: HookConfigurationWriter
    private let hookSupportDirectory: URL
    private let antigravityWorkspaceTruster: (@Sendable (URL) throws -> Void)?
    private var intentionallyTerminating = Set<UUID>()
    private let resizeVerification: ResizeVerificationPolicy
    private var tmuxProbeCache: (usable: Bool, probedAt: Date)?
    private static let tmuxProbeCacheLifetime: TimeInterval = 5
    private let tmuxSupervisor: TmuxServerSupervisor
    var eventHandler: ((SessionProcessEvent) -> Void)?
    /// Extends a launching agent's environment so its git records commit
    /// attribution. Set by `AppStore`, which owns the attribution service;
    /// `nil` leaves the environment unchanged.
    var commitAttributionEnvironment: (@MainActor (Session, [String: String]) -> [String: String]?)?
    /// Launches Codex, OpenCode and Antigravity with the control endpoint the
    /// iPhone companion answers through (`CompanionRuntimeLaunch`). Off in
    /// tests and UI testing, where launch arguments are asserted verbatim.
    var preparesCompanionRuntimes = false

    /// Non-nil when an older daemonized tmux server was reused (TCC attribution
    /// still broken until the user kills that server and relaunches).
    var tmuxServerOrphanWarning: String? { tmuxSupervisor.orphanWarning }

    enum SessionProcessEvent: Equatable {
        case terminated(sessionID: UUID, exitCode: Int32)
        /// The tmux server did not answer clients, so the session was
        /// launched directly in the PTY instead. Prefer fixing tmux; direct
        /// launch keeps the session usable.
        case launchedWithoutTmux(sessionID: UUID)
    }

    enum LaunchError: LocalizedError, Equatable {
        case executableNotFound(agent: AgentKind, binary: String, configuredPath: String)
        case conversationAlreadyActive(agent: AgentKind, conversationID: String)
        case failedToStart(agent: AgentKind, message: String)
        case folderAccessDenied(folderName: String)

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
            case let .folderAccessDenied(folderName):
                return ProtectedFolderAccess.Denied(folderName: folderName).errorDescription
            }
        }
    }

    init(
        locator: ExecutableLocating = PATHExecutableLocator(),
        processFactory: any PTYProcessCreating = SystemPTYProcessFactory(),
        settingsProvider: @escaping () -> AppSettings = { AppSettings() },
        environmentProvider: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
        tmuxTerminator: any TmuxSessionTerminating = ProcessTmuxSessionTerminator(),
        tmuxGoalDeliverer: any TmuxGoalDelivering = ProcessTmuxGoalDeliverer(),
        tmuxServerProbe: any TmuxServerProbing = ProcessTmuxServerProbe(),
        tmuxClientProbe: any TmuxClientProbing = ProcessTmuxClientProbe(),
        tmuxPaneProbe: any TmuxPaneProbing = ProcessTmuxPaneProbe(),
        conversationOwnershipChecker: any AgentConversationOwnershipChecking = ProcessAgentConversationOwnershipChecker(),
        hookConfigurationWriter: HookConfigurationWriter = HookConfigurationWriter(),
        hookSupportDirectory: URL = TmuxSessionWrapping.defaultSupportDirectory(),
        antigravityWorkspaceTruster: (@Sendable (URL) throws -> Void)? = {
            try AntigravityWorkspaceTrust.ensureTrusted(workspace: $0)
        },
        gitService: any GitServiceProtocol = GitService(),
        resizeVerification: ResizeVerificationPolicy = .default,
        tmuxSupervisor: TmuxServerSupervisor = TmuxServerSupervisor()
    ) {
        self.locator = locator
        self.gitService = gitService
        self.processFactory = processFactory
        self.settingsProvider = settingsProvider
        self.environmentProvider = environmentProvider
        self.tmuxTerminator = tmuxTerminator
        self.tmuxGoalDeliverer = tmuxGoalDeliverer
        self.tmuxServerProbe = tmuxServerProbe
        self.tmuxClientProbe = tmuxClientProbe
        self.tmuxPaneProbe = tmuxPaneProbe
        self.conversationOwnershipChecker = conversationOwnershipChecker
        self.hookConfigurationWriter = hookConfigurationWriter
        self.hookSupportDirectory = hookSupportDirectory
        self.antigravityWorkspaceTruster = antigravityWorkspaceTruster
        self.resizeVerification = resizeVerification
        self.tmuxSupervisor = tmuxSupervisor
    }

    /// How patiently a resize is verified against tmux before the client is
    /// reattached. Injectable so tests can exercise the recovery path without
    /// waiting out the production backoff.
    struct ResizeVerificationPolicy: Sendable {
        /// Number of probes before a disagreement is treated as real.
        var attempts: Int
        /// Delay before the first probe; doubled for each subsequent one.
        var baseDelay: Duration

        static let `default` = ResizeVerificationPolicy(attempts: 4, baseDelay: .milliseconds(250))
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

        do {
            try ProtectedFolderAccess.requireReadable(session.workingDirectory)
        } catch let denied as ProtectedFolderAccess.Denied {
            throw LaunchError.folderAccessDenied(folderName: denied.folderName)
        }

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

        // Ensure Antigravity's workspace trust is recorded so the interactive
        // trust confirmation dialog ("Do you trust the contents of this project?")
        // is skipped automatically.
        if session.agent == .antigravity {
            try? antigravityWorkspaceTruster?(session.workingDirectory)
        }

        let provider = CLIAgentProvider(kind: session.agent)
        let settings = settingsProvider()

        // Scoped to the agent's own process tree, which is what makes the
        // attribution hooks safe: git outside that tree never runs them, so
        // the user's own commits are never recorded.
        let inheritedEnvironment = environmentProvider()
        let environmentKeysToUnset = ChildProcessEnvironment.blockedVariableNames(in: inheritedEnvironment)
        var baseEnvironment = ChildProcessEnvironment.sanitized(inheritedEnvironment)
        baseEnvironment[HostAppAwareness.environmentKey] = HostAppAwareness.Host.current.bundleIdentifier
        if hooksConfigured {
            baseEnvironment[HookConfigurationWriter.eventFileEnvironmentKey] =
                HookConfigurationWriter.eventFilePath(
                    for: session.id,
                    supportDirectory: hookSupportDirectory
                ).path
        }
        if let attributionEnvironment = commitAttributionEnvironment?(session, baseEnvironment) {
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
            mode: session.startingMode,
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
        plan.arguments += HostAppAwareness.launchArguments(for: session.agent)
        guard var resolvedExecutable = resolveExecutable(plan: plan) else {
            throw LaunchError.executableNotFound(
                agent: session.agent,
                binary: plan.binaryName,
                configuredPath: plan.configuredPath
            )
        }
        // Best-effort like hooks: without a control endpoint the session
        // still runs, and the phone shows "Needs the terminal" instead.
        if preparesCompanionRuntimes {
            do {
                resolvedExecutable = try CompanionRuntimeLaunch.prepare(
                    plan: &plan,
                    session: session,
                    executable: resolvedExecutable,
                    support: hookSupportDirectory,
                    reattaching: hasLiveTmuxSession
                )
            } catch {
                Logger(subsystem: "com.niclassslua.flotilla", category: "Companion")
                    .error("Companion runtime for \(session.id) unavailable: \(error.localizedDescription)")
            }
        }
        // Covers an already-running server; the `-f` config passed to
        // `new-session` below covers the cold-socket case this cannot.
        var tmuxConfigurationFile: URL?
        if let tmuxExecutable {
            tmuxConfigurationFile = TmuxSessionWrapping.writeConfigurationFile()
            if !hasConfiguredGlobalOptions {
                hasConfiguredGlobalOptions = true
                Task.detached(priority: .utility) {
                    for option in TmuxSessionWrapping.globalOptions {
                        let setOptionProcess = ChildProcessEnvironment.makeProcess()
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
            configurationFile: tmuxConfigurationFile,
            environmentKeysToUnset: environmentKeysToUnset,
            supportDirectory: hookSupportDirectory
        )

        let process = processFactory.makeProcess()
        // Prefer the size this session was last actually displayed at. Falling
        // back to the constant on every launch is what made resize recovery
        // self-defeating: a reattach triggered by a size mismatch relaunched at
        // 100 × 30, so the *next* verification mismatched too, and the second
        // one exhausted the rate limit and stranded the session at that size.
        // Reattaching at the size we already know keeps the recovery
        // non-destructive, which is the whole point of it.
        let size = latestExpectedSizes[session.id] ?? PTYSize(cols: 100, rows: 30)
        process.terminationHandler = { [weak self, weak process] exitCode in
            Task { @MainActor [weak self] in
                guard let self, let process else { return }
                // Only the currently registered process may clear/consume the
                // intentional-terminate flag. A stale exit from a replaced
                // client must not clear a newer process's intentional stop.
                guard self.processes[session.id] === process else { return }
                self.processes[session.id] = nil
                if self.intentionallyTerminating.remove(session.id) == nil {
                    self.eventHandler?(.terminated(sessionID: session.id, exitCode: exitCode))
                }
            }
        }

        // When wrapped in tmux, the pane's working directory is specified via `-c`
        // in `launch.arguments`. The outer tmux client PTY runs from `/` — the
        // server itself is already started under Flotilla as a non-daemon child
        // (`TmuxServerSupervisor`), so this no longer forks a launchd-orphaned
        // daemon whose cwd could pin to a deleted worktree.
        let ptyWorkingDirectory = tmuxExecutable == nil ? session.workingDirectory : URL(fileURLWithPath: "/")
        do {
            try process.start(
                executable: launch.executable,
                arguments: launch.arguments,
                environment: launch.environment,
                workingDirectory: ptyWorkingDirectory,
                initialSize: size
            )
        } catch {
            throw LaunchError.failedToStart(agent: session.agent, message: error.localizedDescription)
        }

        // Mark wrapped only after the PTY actually started — a failed start
        // must not report `isTmuxWrapped` or invite kill-session on a name
        // that never ran.
        tmuxWrappedSessions[session.id] = tmuxExecutable
        processes[session.id] = process
        activeSessions[session.id] = session
        scheduleGoalDelivery(
            sessionID: session.id,
            initialInput: plan.initialInput,
            tmuxExecutable: tmuxExecutable,
            process: process
        )
        return process
    }

    /// Cancels any in-flight delivery for `sessionID`, then either sends
    /// `initialInput` on the raw PTY or schedules tmux `send-keys` delivery.
    private func scheduleGoalDelivery(
        sessionID: UUID,
        initialInput: Data?,
        tmuxExecutable: URL?,
        process: PTYProcessProtocol
    ) {
        goalDeliveryTasks[sessionID]?.cancel()
        goalDeliveryTasks[sessionID] = nil
        guard let initialInput else { return }
        if let tmuxExecutable {
            // Deliver the plan bytes (e.g. `/plan …`), not the bare goal —
            // Codex plan mode withholds the goal from argv and relies on this.
            let text = String(decoding: initialInput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let deliverer = tmuxGoalDeliverer
            let sessionName = TmuxSessionWrapping.sessionName(for: sessionID)
            goalDeliveryTasks[sessionID] = Task.detached(priority: .userInitiated) {
                try deliverer.deliverGoal(text, toSessionNamed: sessionName, tmuxExecutable: tmuxExecutable)
            }
        } else {
            process.send(input: initialInput)
        }
    }

    func isTmuxWrapped(sessionID: UUID) -> Bool {
        tmuxWrappedSessions[sessionID] != nil
    }

    /// How this session's agent exited, if tmux holds its pane open dead.
    /// `nil` for a live pane and for a session not wrapped in tmux — the
    /// latter's exit arrives through `terminationHandler` instead.
    func deadPaneExit(for sessionID: UUID) async -> TmuxPaneExit? {
        guard let tmuxExecutable = tmuxWrappedSessions[sessionID] else { return nil }
        let probe = tmuxPaneProbe
        let name = TmuxSessionWrapping.sessionName(for: sessionID)
        return await Task.detached(priority: .userInitiated) {
            probe.deadPaneExit(sessionNamed: name, tmuxExecutable: tmuxExecutable)
        }.value
    }

    /// Sends a message to a running agent so that it is *submitted*, not
    /// merely typed.
    ///
    /// The same fork as initial-goal delivery above, and for the same reason:
    /// a raw PTY write leaves the text sitting in the agent's composer, so a
    /// tmux-wrapped session has to go through `send-keys`/`paste-buffer`,
    /// which is the sequence confirmed to actually submit. The call returns
    /// only after tmux confirms both the content and submit key were accepted.
    func deliverMessage(_ text: String, to sessionID: UUID) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MessageDeliveryError.emptyMessage }
        guard let process = processes[sessionID], process.isRunning else {
            throw MessageDeliveryError.noLiveProcess
        }
        guard let tmuxExecutable = tmuxWrappedSessions[sessionID] else {
            throw MessageDeliveryError.reliableTransportUnavailable
        }

        // One in-flight delivery per session: cancel/replace any goal or
        // prior message so send-keys cannot interleave into the same pane.
        // Store the detached task itself — wrapping it in another Task meant
        // canceling `goalDeliveryTasks` never reached the deliverer (#76/#48).
        goalDeliveryTasks[sessionID]?.cancel()
        let deliverer = tmuxGoalDeliverer
        let sessionName = TmuxSessionWrapping.sessionName(for: sessionID)
        let delivery = Task.detached(priority: .userInitiated) {
            try deliverer.deliverGoal(trimmed, toSessionNamed: sessionName, tmuxExecutable: tmuxExecutable)
        }
        goalDeliveryTasks[sessionID] = delivery
        try await delivery.value
    }

    enum MessageDeliveryError: LocalizedError, Equatable {
        case emptyMessage
        case noLiveProcess
        case reliableTransportUnavailable

        var errorDescription: String? {
            switch self {
            case .emptyMessage: "The review message is empty."
            case .noLiveProcess: "The session has no running agent."
            case .reliableTransportUnavailable: "Reliable message delivery requires a tmux-backed session."
            }
        }
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
    /// If tmux's client size still does not match after several probes, the
    /// client is non-destructively reattached, up to a rate limit of 2
    /// attempts per minute per session.
    func verifyAndRecoverResize(
        sessionID: UUID,
        expectedSize: PTYSize,
        onRecoveryFailure: (@MainActor (String) -> Void)? = nil
    ) {
        guard let tmuxExecutable = tmuxWrappedSessions[sessionID] else { return }
        let sessionName = TmuxSessionWrapping.sessionName(for: sessionID)
        let probe = tmuxClientProbe
        let policy = resizeVerification
        latestExpectedSizes[sessionID] = expectedSize

        verifyResizeTasks[sessionID]?.cancel()
        verifyResizeTasks[sessionID] = Task { [weak self] in
            let log = Logger(subsystem: "com.niclassslua.flotilla", category: "TerminalResize")
            var lastReported: PTYSize?

            for attempt in 0..<policy.attempts {
                // Doubling backoff — 250, 500, 1000, 2000 ms by default —
                // generous enough that a busy machine is not mistaken for a
                // wedged tmux client.
                try? await Task.sleep(for: policy.baseDelay * (1 << attempt))
                guard !Task.isCancelled,
                      let self,
                      self.latestExpectedSizes[sessionID] == expectedSize
                else { return }

                let reportedSize = await Task.detached(priority: .utility) {
                    probe.clientSize(sessionNamed: sessionName, tmuxExecutable: tmuxExecutable)
                }.value

                guard !Task.isCancelled, self.latestExpectedSizes[sessionID] == expectedSize else { return }

                // No client attached, or the probe failed — that is not
                // evidence of a mismatch, so it is not grounds for a reattach.
                guard let reportedSize else { return }
                lastReported = reportedSize

                if reportedSize == expectedSize {
                    log.notice(
                        "Resize check for \(sessionID): settled at \(reportedSize.cols)x\(reportedSize.rows) after \(attempt + 1) probe(s)"
                    )
                    return
                }
            }

            guard let lastReported, let self else { return }
            log.error(
                "Resize mismatch for \(sessionID): expected \(expectedSize.cols)x\(expectedSize.rows), tmux still reports \(lastReported.cols)x\(lastReported.rows) after \(policy.attempts) probes — triggering reattach recovery"
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
    /// server is provably not answering clients. Starts Flotilla's non-daemon
    /// tmux server first so TCC can attribute folder access to the app. A
    /// wedged server still falls back to a direct PTY launch. The verdict is
    /// cached briefly so restoring several sessions at launch costs one
    /// probe, not one subprocess per session.
    private func usableTmuxExecutable(for sessionID: UUID) -> URL? {
        guard let executable = locator.locate("tmux") else { return nil }
        if let cache = tmuxProbeCache,
           Date().timeIntervalSince(cache.probedAt) < Self.tmuxProbeCacheLifetime {
            return cache.usable ? executable : nil
        }
        // Probe before starting: a wedged server (or a test double that
        // reports unusable) must not spawn a fresh `-D` child.
        let usable = tmuxServerProbe.serverIsUsable(tmuxExecutable: executable)
        guard usable else {
            tmuxProbeCache = (false, Date())
            eventHandler?(.launchedWithoutTmux(sessionID: sessionID))
            return nil
        }
        switch tmuxSupervisor.ensureRunning(tmuxExecutable: executable) {
        case .unavailable:
            tmuxProbeCache = (false, Date())
            eventHandler?(.launchedWithoutTmux(sessionID: sessionID))
            return nil
        case .runningUnderFlotilla, .reusingOrphanedServer:
            tmuxProbeCache = (true, Date())
            return executable
        }
    }

    /// Starts (or detects) the Flotilla tmux server before session restore so
    /// an orphaned-daemon warning can surface even when no session starts.
    func prepareTmuxServer() {
        guard let executable = locator.locate("tmux") else { return }
        _ = tmuxSupervisor.ensureRunning(tmuxExecutable: executable)
    }

    /// Stops the non-daemon tmux server Flotilla owns. Call on app quit so
    /// the server is not reparented to launchd (which would break TCC again).
    /// `restoreSessions()` recreates agent panes on the next launch.
    func shutdownTmuxServer() {
        tmuxSupervisor.shutdown()
        tmuxProbeCache = nil
        hasConfiguredGlobalOptions = false
    }

    /// Kills the underlying tmux session too, not just the outer attached
    /// client — a plain `process.terminate()` would only detach the client
    /// and leave the tmux session (and the agent inside it) running forever.
    /// Caller-initiated terminations are exactly the cases that must not
    /// survive: restart (a fresh agent is wanted) and delete (full cleanup).
    /// App quit stops the whole tmux server via `shutdownTmuxServer()`; on
    /// relaunch, `restoreSessions()` starts agents again.
    func terminate(sessionID: UUID) {
        stopClient(sessionID: sessionID)
        // The tmux session outlives its client, and its agent keeps running
        // detached unless the server-side session is killed explicitly.
        // This must complete before a restart's `new-session -A` runs, or
        // the two could race (kill-session landing after the fresh session
        // was created, killing the new agent too).
        if let tmuxExecutable = tmuxWrappedSessions[sessionID] {
            tmuxWrappedSessions[sessionID] = nil
            let name = TmuxSessionWrapping.sessionName(for: sessionID)
            tmuxTerminator.killSession(named: name, tmuxExecutable: tmuxExecutable)
            // A racy/failed kill must not leave `flotilla-<UUID>` until relaunch.
            if tmuxTerminator.listSessions(tmuxExecutable: tmuxExecutable).contains(name) {
                tmuxTerminator.killSession(named: name, tmuxExecutable: tmuxExecutable)
            }
        }
    }

    /// Delete's teardown: `terminate` plus `killServerSideSession`, but with
    /// a single `kill-session` run off the main actor. A deleted session's
    /// name is never reused, so unlike restart there is no race to wait out,
    /// and a slow tmux must not freeze the UI.
    func terminateForDeletion(sessionID: UUID) {
        stopClient(sessionID: sessionID)
        tmuxWrappedSessions[sessionID] = nil
        latestExpectedSizes[sessionID] = nil
        guard let tmuxExecutable = locator.locate("tmux") else { return }
        let terminator = tmuxTerminator
        let name = TmuxSessionWrapping.sessionName(for: sessionID)
        Task.detached(priority: .utility) {
            terminator.killSession(named: name, tmuxExecutable: tmuxExecutable)
            // Retry once if the session survived the first kill — orphaned
            // panes must not wait for the next cold `restoreSessions` reap.
            if terminator.listSessions(tmuxExecutable: tmuxExecutable).contains(name) {
                terminator.killSession(named: name, tmuxExecutable: tmuxExecutable)
            }
        }
    }

    /// Stops the attached client and drops per-session bookkeeping, leaving
    /// the server-side tmux session to the caller.
    private func stopClient(sessionID: UUID) {
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
        // Do NOT remove processes[sessionID] here — the process's
        // terminationHandler will clear it once the exit callback fires.
    }

}
