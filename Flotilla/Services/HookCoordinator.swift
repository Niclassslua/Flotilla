import Foundation
import Observation
import UserNotifications
import SessionKit
import ProcessKit
import HooksKit

/// Wires one `SessionScreenMonitor` per running session to the app's
/// `AppStore` (status updates) and a `NotificationDispatching` (macOS
/// notifications), via `WaitingNotificationGate` so a notification fires
/// only on the transition into waiting, not on every poll that still sees
/// the prompt.
///
/// Status comes from what each agent draws on its screen. Inferring it from
/// output volume instead — the previous approach — could not distinguish an
/// agent doing work from a terminal redrawing itself, so merely opening a
/// session's tab was enough to mark it "Working".
@Observable
@MainActor
final class HookCoordinator {
    private let store: AppStore
    let screenReader: any SessionScreenReading
    private let dispatcher: NotificationDispatching
    private let notificationsEnabled: @MainActor () -> Bool
    private let hookSupportDirectory: URL
    private var monitors: [UUID: SessionScreenMonitor] = [:]
    private var hookReceivers: [UUID: HookEventReceiver] = [:]
    private var codexStatusObservers: [UUID: CodexAppServerStatusObserver] = [:]
    private var gates: [UUID: WaitingNotificationGate] = [:]
    private var arbiters: [UUID: SessionStatusObservationArbiter] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// Surfaced in the UI (behind an always-mounted, near-invisible label)
    /// so a UI test can observe that a notification fired without needing
    /// to inspect the real, out-of-process system Notification Center.
    private(set) var lastNotifiedSessionTitle: String?

    /// `requestsAuthorization` is false under `UI_TESTING`: the real
    /// `UNUserNotificationCenter` authorization prompt is a genuine system
    /// TCC dialog (ad-hoc/local code signing means it can re-prompt on
    /// every fresh build, since macOS keys the decision to the code
    /// signature), and it can block the app's main window from ever
    /// appearing until dismissed — automated tests must never risk that.
    init(
        store: AppStore,
        screenReader: any SessionScreenReading,
        dispatcher: NotificationDispatching = SystemNotificationDispatcher(),
        requestsAuthorization: Bool = true,
        isConfiguredToNotify: (@MainActor () -> Bool)? = nil,
        notificationsEnabled: @escaping @MainActor () -> Bool = { true },
        hookSupportDirectory: URL = TmuxSessionWrapping.defaultSupportDirectory()
    ) {
        self.store = store
        self.screenReader = screenReader
        self.dispatcher = dispatcher
        self.notificationsEnabled = notificationsEnabled
        self.hookSupportDirectory = hookSupportDirectory
        store.onAgentChanged = { [weak self] sessionID in
            self?.resync(sessionID: sessionID)
        }
        let shouldRequestAuth = isConfiguredToNotify?() ?? notificationsEnabled()
        if requestsAuthorization, shouldRequestAuth, ProcessInfo.processInfo.environment["UI_TESTING"] != "1" {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        if !ProcessInfo.processInfo.environment.keys.contains("UI_TESTING") || ProcessInfo.processInfo.environment["UI_TESTING_SIMULATE_WAITING_SESSION"] != nil {
            observeAll()
        }
    }

    /// Starts watching any session that isn't being watched yet — safe to
    /// call again whenever the session list changes (idempotent per session
    /// via the `monitors` dictionary check in `observe`).
    func observeAll() {
        let activeIDs = Set(store.sessions.map(\.id))
        for sessionID in monitors.keys where !activeIDs.contains(sessionID) || store.process(for: sessionID) == nil {
            monitors[sessionID]?.stop()
            hookReceivers[sessionID]?.stop()
            codexStatusObservers[sessionID]?.stop()
            tasks[sessionID]?.cancel()
            monitors[sessionID] = nil
            hookReceivers[sessionID] = nil
            codexStatusObservers[sessionID] = nil
            tasks[sessionID] = nil
            gates[sessionID] = nil
            arbiters[sessionID] = nil
        }
        for session in store.sessions where store.process(for: session.id) != nil {
            observe(sessionID: session.id)
        }
    }

    /// Runs `SessionScreenMonitor` for every session, and — for agent kinds
    /// `HookConfigurationWriter` supports — a `HookEventReceiver` alongside
    /// it. Codex additionally gets a private app-server status observer. All
    /// feeds enter the same `handle` funnel. This is deliberately
    /// "both, always" rather than "hook primary, screen fallback on
    /// timeout": a broken hook pipe (event-file creation failure, agent
    /// restyle) then degrades to exactly today's screen-only behavior
    /// instead of to no status at all, with no timeout/cutover logic to get
    /// wrong.
    /// `applyObservedStatus`'s existing no-op-on-unchanged-status guard
    /// keeps two agreeing sources from being noisier than one.
    /// Rebuilds this session's observation against the agent it is running
    /// *now*.
    ///
    /// `observe(sessionID:)` is idempotent by design and returns early when a
    /// monitor already exists, and the `HookEventReceiver` it builds captures
    /// the session's `AgentKind` for its lifetime — `observation(forLine:agent:)`
    /// branches its entire JSON schema on that value. After a handoff the
    /// session is a different agent writing a different hook format, so the
    /// receiver must be replaced rather than reused; left alone it parses the
    /// new agent's events against the old agent's schema and silently drops
    /// them, degrading status to the screen heuristic alone.
    ///
    /// `observeAll()`'s teardown cannot cover this: it keys off
    /// `store.process(for:) == nil`, and `SessionProcessManager.terminate`
    /// deliberately leaves the process entry in place until the exit handler
    /// fires, so that condition is not yet true when the move happens.
    func resync(sessionID: UUID) {
        monitors[sessionID]?.stop()
        hookReceivers[sessionID]?.stop()
        codexStatusObservers[sessionID]?.stop()
        tasks[sessionID]?.cancel()
        monitors[sessionID] = nil
        hookReceivers[sessionID] = nil
        codexStatusObservers[sessionID] = nil
        tasks[sessionID] = nil
        gates[sessionID] = nil
        arbiters[sessionID] = nil
        observe(sessionID: sessionID)
    }

    private func observe(sessionID: UUID) {
        guard monitors[sessionID] == nil else { return }
        guard let session = store.sessions.first(where: { $0.id == sessionID }) else { return }

        let monitor = SessionScreenMonitor(
            sessionID: sessionID,
            reader: screenReader,
            heuristic: TerminalScreenHeuristic(agent: session.agent)
        )
        let gate = WaitingNotificationGate()
        monitors[sessionID] = monitor
        gates[sessionID] = gate
        // A session that already carries a persisted status has a history —
        // its screen-derived `.readyForReview` is not the boot-screen misread
        // the arbiter guards against, so it starts un-gated. A brand-new
        // session (`nil` status) must earn `.readyForReview`.
        arbiters[sessionID] = SessionStatusObservationArbiter(
            sessionHasProgressed: session.status != nil
        )

        var hookReceiver: HookEventReceiver?
        if HookConfigurationWriter.supportsHooks(for: session.agent) {
            let receiver = HookEventReceiver(
                filePath: HookConfigurationWriter.eventFilePath(for: sessionID, supportDirectory: hookSupportDirectory),
                agent: session.agent
            )
            hookReceivers[sessionID] = receiver
            hookReceiver = receiver
        }

        var codexObserver: CodexAppServerStatusObserver?
        if session.agent == .codexCLI,
           let descriptor = CompanionRuntimeDescriptor.read(sessionID, support: hookSupportDirectory),
           descriptor.agent == .codexCLI {
            let observer = CodexAppServerStatusObserver(session: session, endpoint: descriptor.endpoint)
            observer.onThreadID = { [weak self] id in
                self?.store.adoptAgentSessionID(id, forSessionID: sessionID)
            }
            codexStatusObservers[sessionID] = observer
            codexObserver = observer
        }

        tasks[sessionID] = Task { [weak self] in
            monitor.start()
            hookReceiver?.start()
            codexObserver?.start()
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await observation in monitor.observationStream {
                        await self?.handle(
                            observation: observation,
                            source: .screen,
                            sessionID: sessionID,
                            gate: gate
                        )
                    }
                }
                if let hookReceiver {
                    group.addTask {
                        for await observation in hookReceiver.observationStream {
                            await self?.handle(
                                observation: observation,
                                source: .hook,
                                sessionID: sessionID,
                                gate: gate
                            )
                        }
                    }
                    group.addTask {
                        for await event in hookReceiver.permissionRequestStream {
                            await self?.recordPermissionRequest(event, sessionID: sessionID)
                        }
                    }
                    group.addTask {
                        for await event in hookReceiver.sessionIdentityStream {
                            await self?.store.adoptAgentSessionID(
                                event.nativeSessionID,
                                forSessionID: sessionID
                            )
                        }
                    }
                }
                if let codexObserver {
                    group.addTask {
                        for await observation in codexObserver.observationStream {
                            await self?.handle(
                                observation: observation,
                                source: .appServer,
                                sessionID: sessionID,
                                gate: gate
                            )
                        }
                    }
                }
            }
        }
    }

    private func handle(
        observation: SessionStatusObservation,
        source: SessionStatusObservationArbiter.Source,
        sessionID: UUID,
        gate: WaitingNotificationGate
    ) async {
        // A dead agent's pane stays open under `remain-on-exit`, so its exit
        // is only visible on screen. Once tmux confirms it, the store has
        // settled the status from the real exit code and the screen has
        // nothing further to say.
        if source == .screen,
           observation.suggestsAgentExit,
           await store.confirmAgentExit(sessionID: sessionID) {
            return
        }
        var arbiter = arbiters[sessionID] ?? SessionStatusObservationArbiter()
        let accepted = arbiter.accept(observation, from: source)
        let sourceLabel: String
        switch source {
        case .hook: sourceLabel = "hook"
        case .appServer: sourceLabel = "Codex app-server"
        case .screen: sourceLabel = "screen"
        }
        let session = store.sessions.first(where: { $0.id == sessionID })
        let sessionTitle = session?.title ?? "untitled"
        let agentLabel = session?.agent.displayName ?? "unknown"
        let currentStatus = SessionStatusTrace.describe(
            session?.status, session?.waitingReason
        )
        let rejectionReason = accepted == nil
            ? (arbiter.lastRejectionCause ?? "arbiter declined it")
            : nil
        SessionStatusTrace.observed(
            sessionID: sessionID,
            title: sessionTitle,
            agent: agentLabel,
            currentStatus: currentStatus,
            source: sourceLabel,
            observation: observation.debugDescription,
            accepted: accepted != nil,
            rejectionReason: rejectionReason
        )
        arbiters[sessionID] = arbiter
        guard let accepted else { return }

        let shouldNotify = gate.shouldNotify(for: accepted.status)
        store.applyObservedStatus(
            accepted.status,
            waitingReason: accepted.waitingReason,
            origin: .observation(source: sourceLabel, cause: accepted.cause),
            toSessionID: sessionID
        )
        await store.syncAgentTitle(forSessionID: sessionID)
        if shouldNotify,
           notificationsEnabled(),
           let session = store.sessions.first(where: { $0.id == sessionID }) {
            lastNotifiedSessionTitle = session.title
            await dispatcher.notifyWaitingForInput(sessionTitle: session.title, sessionID: sessionID)
        }
    }

    /// Logs one permission ask for Home's Top permissions widget. Never
    /// throws into the caller — a write failure here must not disrupt
    /// status tracking, which shares this same event stream's task group.
    private func recordPermissionRequest(_ event: HookPermissionRequestEvent, sessionID: UUID) async {
        let pattern = PermissionPattern.normalize(event: event)
        try? store.permissionLogStore.record(
            sessionID: sessionID.uuidString,
            agent: event.agent.rawValue,
            tool: event.toolName,
            pattern: pattern,
            at: event.timestamp
        )
    }
}
