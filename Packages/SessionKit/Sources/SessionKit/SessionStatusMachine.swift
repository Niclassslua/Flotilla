import Foundation
import os

/// The only place transition legality is decided.
///
/// A session with no status yet (`nil` — created, no work observed) accepts
/// any first status. `crashed` is the one near-terminal state: it reopens
/// only through `working`, which is where an explicit restart lands.
/// Everything else moves freely, so a session that looked review-ready and
/// then resumes work is never stuck.
public struct SessionStatusMachine: Sendable {
    public init() {}

    public func canTransition(from: SessionStatus?, to: SessionStatus) -> Bool {
        guard let from else {
            // First observed status for a brand-new session.
            return true
        }
        if from == to {
            // Self-transitions are no-ops handled by callers, never legal here.
            return false
        }
        if from == .crashed {
            return to == .working
        }
        return true
    }

    /// The refusal log below shares the app's `SessionStatus` category, so an
    /// illegal transition lands in the same stream as the transitions that
    /// succeeded — see `SessionStatusTrace` in the app target.
    private static let logger = Logger(subsystem: "com.niclassslua.flotilla", category: "SessionStatus")

    /// Returns `session` unchanged if the transition isn't legal, and logs the
    /// illegal attempt so operators can diagnose unexpected state immutability.
    /// Callers in the app layer log the *legal* ones with their cause; this
    /// only covers the refusals, which callers cannot describe as precisely.
    public func transition(_ session: Session, to newStatus: SessionStatus, now: Date = Date()) -> Session {
        guard canTransition(from: session.status, to: newStatus) else {
            // Logged rather than silently no-op'd: an unexplained refusal here
            // is exactly what makes a session look stuck in the UI.
            let from = session.status?.rawValue ?? "none"
            let reason = session.status == newStatus
                ? "self-transition"
                : "\(from) is not allowed to become \(newStatus.rawValue)"
            Self.logger.info(
                """
                \(session.id.uuidString.prefix(8), privacy: .public) refused \(from, privacy: .public) → \
                \(newStatus.rawValue, privacy: .public) — \(reason, privacy: .public)
                """
            )
            return session
        }
        var updated = session
        updated.status = newStatus
        if newStatus != .waitingForInput {
            updated.waitingReason = nil
        }
        updated.statusChangedAt = now
        updated.lastActiveAt = now
        return updated
    }
}
