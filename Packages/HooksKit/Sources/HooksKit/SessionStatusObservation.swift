import SessionKit

/// A status reported by a provider hook or the rendered terminal, including
/// the user action required when that status is `waitingForInput`.
public struct SessionStatusObservation: Equatable, Sendable {
    public let status: SessionStatus
    public let waitingReason: SessionWaitingReason?

    public init(_ status: SessionStatus, waitingReason: SessionWaitingReason? = nil) {
        self.status = status
        self.waitingReason = status == .waitingForInput ? waitingReason : nil
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

    public init() {}

    public mutating func accept(
        _ observation: SessionStatusObservation,
        from source: Source
    ) -> SessionStatusObservation? {
        if source == .hook {
            latestHookObservation = observation
            return observation
        }

        if let hook = latestHookObservation {
            if hook.status == .waitingForInput, observation.status == .readyForReview {
                return nil
            }
            if hook.status == .waitingForInput,
               observation.status == .waitingForInput,
               let hookReason = hook.waitingReason,
               observation.waitingReason != hookReason {
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
