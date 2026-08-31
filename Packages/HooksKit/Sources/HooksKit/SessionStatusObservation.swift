import SessionKit

/// A status reported by a provider hook or the rendered terminal, including
/// the user action required when that status is `waitingForInput`.
public struct SessionStatusObservation: Equatable, Sendable {
    public let status: SessionStatus
    public let waitingReason: SessionWaitingReason?
    /// Why this observation says what it says — the hook event name, the
    /// screen marker that matched, or the fallback branch that was reached.
    /// Diagnostics only: it is deliberately excluded from `==` so that
    /// de-duplication upstream (`SessionScreenMonitor` skips a repeat of the
    /// previous observation) still collapses the same status arriving from a
    /// different marker, exactly as it did before causes existed.
    public let cause: String?

    public init(
        _ status: SessionStatus,
        waitingReason: SessionWaitingReason? = nil,
        cause: String? = nil
    ) {
        self.status = status
        self.waitingReason = status == .waitingForInput ? waitingReason : nil
        self.cause = cause
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.status == rhs.status && lhs.waitingReason == rhs.waitingReason
    }

    /// `working (esc to interrupt)` — the compact form used in log lines.
    public var debugDescription: String {
        var text = "\(status.rawValue)"
        if let waitingReason {
            text += "/\(waitingReason.rawValue)"
        }
        if let cause {
            text += " ← \(cause)"
        }
        return text
    }
}

/// Structured hook events outrank an ambiguous terminal fallback. This keeps
/// a hook-reported Plan Ready / waiting state from immediately decaying to a
/// bare Ready for Review merely because the provider's prompt styling was
/// not recognized.
public struct SessionStatusObservationArbiter: Sendable {
    public enum Source: Equatable, Sendable {
        case hook
        case screen
    }

    private var latestHookObservation: SessionStatusObservation?

    /// Why the most recent `accept` returned `nil`, for diagnostics. A
    /// suppressed observation is the hardest kind of status behaviour to
    /// explain from the outside ("the screen clearly says Ready for Review,
    /// so why is the card still Waiting?"), so the arbiter records its
    /// reasoning instead of discarding it silently.
    public private(set) var lastRejectionCause: String?

    public init() {}

    public mutating func accept(
        _ observation: SessionStatusObservation,
        from source: Source
    ) -> SessionStatusObservation? {
        lastRejectionCause = nil
        if source == .hook {
            latestHookObservation = observation
            return observation
        }

        if let hook = latestHookObservation {
            if hook.status == .waitingForInput, observation.status == .readyForReview {
                lastRejectionCause = "screen readyForReview outranked by pending hook waitingForInput"
                    + (hook.waitingReason.map { "/\($0.rawValue)" } ?? "")
                return nil
            }
            if hook.status == .waitingForInput,
               observation.status == .waitingForInput,
               let hookReason = hook.waitingReason,
               observation.waitingReason != hookReason {
                lastRejectionCause = "screen waiting reason "
                    + (observation.waitingReason?.rawValue ?? "none")
                    + " disagrees with pending hook reason \(hookReason.rawValue)"
                return nil
            }
        }

        // A visibly active or interactive screen belongs to a newer episode
        // than the last terminal hook edge. Let future screen states stand on
        // their own until another structured hook arrives.
        if observation.status == .working || observation.status == .crashed ||
            (observation.status == .waitingForInput && latestHookObservation?.status != .waitingForInput) {
            latestHookObservation = nil
        }
        return observation
    }
}
