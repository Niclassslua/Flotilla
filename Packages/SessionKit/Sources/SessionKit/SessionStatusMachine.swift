import Foundation

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

    /// Returns `session` unchanged if the transition isn't legal, and logs the
/// illegal attempt so operators can diagnose unexpected state immutability.
    public func transition(_ session: Session, to newStatus: SessionStatus, now: Date = Date()) -> Session {
        guard canTransition(from: session.status, to: newStatus) else {
            // Log illegal transition for diagnostics — this used to be a silent
            // no-op, which made it hard to understand why sessions got stuck.
            print("SessionStatusMachine: illegal transition from \(session.status.map { "\($0)" } ?? "nil") to \(newStatus), session \(session.id) unchanged")
            return session
        }
        var updated = session
        updated.status = newStatus
        if newStatus != .waitingForInput {
            updated.waitingReason = nil
        }
        updated.lastActiveAt = now
        return updated
    }
}
