import Foundation
import AgentKit
import SessionKit
import ProcessKit
import SettingsKit

/// Owns the live `PTYProcessProtocol` for every session that has been
/// started, keyed by session id. Sessions keep running here across sidebar
/// selection changes — Phase 7's terminal view just attaches to whatever
/// is already running rather than owning process lifecycle itself.
@MainActor
final class SessionProcessManager {
    private var processes: [UUID: PTYProcessProtocol] = [:]
    private var tmuxWrappedSessions: [UUID: URL] = [:]
    private let locator: ExecutableLocating
    private let processFactory: any PTYProcessCreating
    private let providers: AgentProviderRegistry
    private let settingsProvider: () -> AppSettings
    private let tmuxTerminator: any TmuxSessionTerminating
    private let tmuxGoalDeliverer: any TmuxGoalDelivering
    private let tmuxServerProbe: any TmuxServerProbing
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
        case failedToStart(agent: AgentKind, message: String)

        var errorDescription: String? {
            switch self {
            case let .executableNotFound(agent, binary, configuredPath):
                if configuredPath.isEmpty {
                    return "\(agent.displayName) was not found. Install ‘\(binary)’ or choose its executable in Settings."
                }
                return "\(agent.displayName) is not executable at \(configuredPath). Choose a valid binary in Settings."
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
        tmuxServerProbe: any TmuxServerProbing = ProcessTmuxServerProbe()
    ) {
        self.locator = locator
        self.processFactory = processFactory
        self.providers = providers
        self.settingsProvider = settingsProvider
        self.tmuxTerminator = tmuxTerminator
        self.tmuxGoalDeliverer = tmuxGoalDeliverer
        self.tmuxServerProbe = tmuxServerProbe
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
        tmuxWrappedSessions[sessionID] = nil
        tmuxTerminator.killSession(
            named: TmuxSessionWrapping.sessionName(for: sessionID),
            tmuxExecutable: tmuxExecutable
        )
    }

    @discardableResult
    func start(session: Session, deliverGoal: Bool = true) throws -> PTYProcessProtocol {
        // A restart is in flight: the registered process was told to die but
        // its exit callback has not landed yet. Returning it would hand the
        // caller a dying process whose eventual exit clears the session's
        // process entry — the "restart does not work" symptom. Start fresh.
        let restartInFlight = intentionallyTerminating.contains(session.id)
        if let existing = processes[session.id], existing.isRunning, !restartInFlight {
            return existing
        }

        intentionallyTerminating.remove(session.id)

        let provider = providers.provider(for: session.agent)
        let settings = settingsProvider()
        let plan = provider.launchPlan(
            goal: deliverGoal ? session.goal : nil,
            model: session.model,
            effort: session.effort,
            settings: settings,
            baseEnvironment: ProcessInfo.processInfo.environment
        )
        guard let resolvedExecutable = resolveExecutable(plan: plan) else {
            throw LaunchError.executableNotFound(
                agent: session.agent,
                binary: plan.binaryName,
                configuredPath: plan.configuredPath
            )
        }
        let tmuxExecutable = usableTmuxExecutable(for: session.id)
        tmuxWrappedSessions[session.id] = tmuxExecutable

        if let tmuxExecutable {
            let setOptionProcess = Process()
            setOptionProcess.executableURL = tmuxExecutable
            setOptionProcess.arguments = TmuxSessionWrapping.socketArguments()
                + ["set-option", "-g", "default-terminal", "tmux-256color"]
            setOptionProcess.standardOutput = FileHandle.nullDevice
            setOptionProcess.standardError = FileHandle.nullDevice
            // Only wait when the process actually started: `waitUntilExit`
            // on a process whose `run()` threw (binary vanished, wrong arch)
            // blocks forever — there is no child to wait for.
            if (try? setOptionProcess.run()) != nil {
                setOptionProcess.waitUntilExit()
            }
        }

        let launch = TmuxSessionWrapping.wrap(
            agentExecutable: resolvedExecutable,
            arguments: plan.arguments,
            environment: plan.environment,
            workingDirectory: session.workingDirectory,
            sessionID: session.id,
            tmuxExecutable: tmuxExecutable
        )

        let process = processFactory.makeProcess()
        // Deliberately narrower than any real terminal surface in this app
        // (the smallest grid tile is ~20-45 columns depending on font size).
        // The CLI's startup banner picks a single- vs two-column layout
        // based on this initial width; guessing wide (e.g. 80) makes it draw
        // a wide banner with absolute cursor placement that overlaps and
        // garbles once SwiftTerm actually renders it in a narrower pane —
        // and those corrupted bytes get persisted into session scrollback.
        // `TerminalController.sizeChanged` corrects this to the real size
        // immediately once a terminal view lays out, so undershooting here
        // is always safe.
        let size = PTYSize(cols: 40, rows: 20)
        process.terminationHandler = { [weak self, weak process] exitCode in
            Task { @MainActor [weak self] in
                guard let self, let process else { return }
                if self.processes[session.id] === process {
                    self.processes[session.id] = nil
                    if self.intentionallyTerminating.remove(session.id) == nil {
                        self.eventHandler?(.terminated(sessionID: session.id, exitCode: exitCode))
                    }
                } else {
                    // A replacement process is registered: this exit belongs
                    // to a superseded lifecycle and must neither clear the
                    // new entry nor surface as an unexpected termination.
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
        if plan.initialInput != nil {
            if let tmuxExecutable {
                // A raw PTY write only ever gets the goal typed, not
                // submitted (see TmuxGoalDelivering's doc comment) — tmux
                // send-keys is the mechanism confirmed to actually work.
                // Detached because the deliverer blocks its thread waiting
                // for the pane to actually be ready; must not run on the
                // main actor.
                let deliverer = tmuxGoalDeliverer
                let trimmedGoal = session.goal.trimmingCharacters(in: .whitespacesAndNewlines)
                let sessionName = TmuxSessionWrapping.sessionName(for: session.id)
                Task.detached(priority: .userInitiated) {
                    deliverer.deliverGoal(trimmedGoal, toSessionNamed: sessionName, tmuxExecutable: tmuxExecutable)
                }
            } else if let initialInput = plan.initialInput {
                process.send(input: initialInput)
            }
        }
        return process
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
}
