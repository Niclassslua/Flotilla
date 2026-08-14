import SessionKit

/// Tracks one session's waiting-state edge so a notification fires exactly
/// once per transition INTO `.waitingForInput`, not on every status update
/// while it stays waiting (or on unrelated status changes).
public final class WaitingNotificationGate: @unchecked Sendable {
    private var isCurrentlyWaiting = false

    public init() {}

    /// Feed each observed status in order; returns `true` only on the
    /// transition into `.waitingForInput`.
    public func shouldNotify(for status: SessionStatus) -> Bool {
        let wasWaiting = isCurrentlyWaiting
        isCurrentlyWaiting = (status == .waitingForInput)
        return isCurrentlyWaiting && !wasWaiting
    }
}
