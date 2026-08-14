import Foundation
import Observation
import UserNotifications
import SessionKit
import ProcessKit
import HooksKit

/// Wires one `SessionStatusObserver` per running session to the app's
/// `AppStore` (status updates) and a `NotificationDispatching` (macOS
/// notifications), via `WaitingNotificationGate` so a notification fires
/// only on the transition into waiting, not on every matching output chunk.
@Observable
@MainActor
final class HookCoordinator {
    private let store: AppStore
    private let dispatcher: NotificationDispatching
    private let notificationsEnabled: @MainActor () -> Bool
    private var observers: [UUID: SessionStatusObserver] = [:]
    private var gates: [UUID: WaitingNotificationGate] = [:]
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
        dispatcher: NotificationDispatching = SystemNotificationDispatcher(),
        requestsAuthorization: Bool = true,
        notificationsEnabled: @escaping @MainActor () -> Bool = { true }
    ) {
        self.store = store
        self.dispatcher = dispatcher
        self.notificationsEnabled = notificationsEnabled
        if requestsAuthorization, notificationsEnabled() {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        observeAll()
    }

    /// Starts observing any session that doesn't have an observer yet —
    /// safe to call again whenever the session list changes (idempotent
    /// per session via the `observers` dictionary check in `observe`).
    func observeAll() {
        let activeIDs = Set(store.sessions.map(\.id))
        for sessionID in observers.keys where !activeIDs.contains(sessionID) || store.process(for: sessionID) == nil {
            observers[sessionID]?.stop()
            tasks[sessionID]?.cancel()
            observers[sessionID] = nil
            tasks[sessionID] = nil
            gates[sessionID] = nil
        }
        for session in store.sessions {
            guard let process = store.process(for: session.id) else { continue }
            observe(session: session, process: process)
        }
    }

    private func observe(session: Session, process: PTYProcessProtocol) {
        guard observers[session.id] == nil else { return }

        let observer = SessionStatusObserver(output: process)
        let gate = WaitingNotificationGate()
        observers[session.id] = observer
        gates[session.id] = gate

        tasks[session.id] = Task { [weak self] in
            observer.start()
            for await status in observer.statusStream {
                await self?.handle(status: status, sessionID: session.id, gate: gate)
            }
        }
    }

    private func handle(status: SessionStatus, sessionID: UUID, gate: WaitingNotificationGate) async {
        let shouldNotify = gate.shouldNotify(for: status)
        store.applyObservedStatus(status, toSessionID: sessionID)
        if shouldNotify,
           notificationsEnabled(),
           let session = store.sessions.first(where: { $0.id == sessionID }) {
            lastNotifiedSessionTitle = session.title
            await dispatcher.notifyWaitingForInput(sessionTitle: session.title)
        }
    }
}
