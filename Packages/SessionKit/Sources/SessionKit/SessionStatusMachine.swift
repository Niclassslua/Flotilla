import Foundation

/// The only place transition legality is decided. A cleanly finished task is
/// terminal; a crashed CLI may be explicitly restarted after configuration
/// or environment issues are corrected.
public struct SessionStatusMachine: Sendable {
    public init() {}

    public func canTransition(from: SessionStatus, to: SessionStatus) -> Bool {
        switch (from, to) {
        // An idle session can absolutely need input: an agent that has been
        // quiet long enough to look idle then asks for permission. Blocking
        // this edge left those sessions reading "Idle" forever.
        case (.idle, .working), (.idle, .waitingForInput), (.idle, .finished), (.idle, .crashed):
            return true
        case (.working, .idle), (.working, .waitingForInput), (.working, .ready), (.working, .finished), (.working, .crashed):
            return true
        case (.waitingForInput, .working), (.waitingForInput, .idle),
             (.waitingForInput, .ready), (.waitingForInput, .finished), (.waitingForInput, .crashed):
            return true
        case (.ready, .working), (.ready, .waitingForInput), (.ready, .idle), (.ready, .finished), (.ready, .crashed):
            return true
        case (.crashed, .working):
            return true
        case (.finished, .working):
            // Allow restarting a finished session — the agent may have completed
            // its task and is now waiting for new instructions at the prompt.
            return true
        default:
            return false
        }
    }

    /// Returns `session` unchanged if the transition isn't legal, and logs the
/// illegal attempt so operators can diagnose unexpected state immutability.
    public func transition(_ session: Session, to newStatus: SessionStatus, now: Date = Date()) -> Session {
        guard canTransition(from: session.status, to: newStatus) else {
            // Log illegal transition for diagnostics — this used to be a silent
            // no-op, which made it hard to understand why sessions got stuck.
            print("SessionStatusMachine: illegal transition from \(session.status) to \(newStatus), session \(session.id) unchanged")
            return session
        }
        var updated = session
        updated.status = newStatus
        updated.lastActiveAt = now
        return updated
    }
}
