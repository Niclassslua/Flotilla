import Foundation

/// The only place transition legality is decided. A cleanly finished task is
/// terminal; a crashed CLI may be explicitly restarted after configuration
/// or environment issues are corrected.
public struct SessionStatusMachine: Sendable {
    public init() {}

    public func canTransition(from: SessionStatus, to: SessionStatus) -> Bool {
        switch (from, to) {
        case (.idle, .working), (.idle, .finished), (.idle, .crashed):
            return true
        case (.working, .idle), (.working, .waitingForInput), (.working, .finished), (.working, .crashed):
            return true
        case (.waitingForInput, .working), (.waitingForInput, .idle),
             (.waitingForInput, .finished), (.waitingForInput, .crashed):
            return true
        case (.crashed, .working):
            return true
        default:
            return false
        }
    }

    /// Returns `session` unchanged if the transition isn't legal.
    public func transition(_ session: Session, to newStatus: SessionStatus, now: Date = Date()) -> Session {
        guard canTransition(from: session.status, to: newStatus) else { return session }
        var updated = session
        updated.status = newStatus
        updated.lastActiveAt = now
        return updated
    }
}
