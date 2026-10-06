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
    /// The screen suggests the agent process itself has exited, not merely
    /// finished a turn. A hint only — screen text can quote the marker — so
    /// the app confirms it with tmux before treating the agent as gone.
    /// Part of `==` so that a live composer's `.readyForReview` followed by
    /// a dead pane's is still reported.
    public let suggestsAgentExit: Bool
    /// The screen shows the provider's own statement that the turn was cut
    /// short ("Interrupted · What should Claude do instead?", and the same
    /// line from Antigravity CLI). An
    /// interrupt fires no hook at all, so this is the one screen signal
    /// allowed to end a hook-held working or waiting episode. Part of `==`
    /// for the same reason as `suggestsAgentExit`.
    public let endsTurn: Bool

    public init(
        _ status: SessionStatus,
        waitingReason: SessionWaitingReason? = nil,
        cause: String? = nil,
        suggestsAgentExit: Bool = false,
        endsTurn: Bool = false
    ) {
        self.status = status
        self.waitingReason = status == .waitingForInput ? waitingReason : nil
        self.cause = cause
        self.suggestsAgentExit = suggestsAgentExit
        self.endsTurn = endsTurn
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.status == rhs.status
            && lhs.waitingReason == rhs.waitingReason
            && lhs.suggestsAgentExit == rhs.suggestsAgentExit
            && lhs.endsTurn == rhs.endsTurn
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

/// Structured provider events outrank an ambiguous terminal fallback. This
/// keeps hook or app-server-reported work/waiting from decaying to a bare Ready
/// for Review merely because a provider briefly redraws without a marker.
public struct SessionStatusObservationArbiter: Sendable {
    public enum Source: Equatable, Sendable {
        case hook
        case appServer
        case screen
    }

    private var latestStructuredObservation: SessionStatusObservation?

    /// Whether this session has shown any sign of life yet — any observation,
    /// from any source, whose status is something other than
    /// `.readyForReview`.
    ///
    /// A screen showing a composer above some text looks the same whether the
    /// agent just finished a turn or the session has only booted into its
    /// welcome screen, so a screen-derived `.readyForReview` is held back
    /// until we have seen the session actually working (or waiting). Calling
    /// a brand-new session "Ready for Review" is the worse misread, and it is
    /// the one users notice. Structured events bypass this gate: they directly
    /// report that a provider turn ended.
    private var sessionHasProgressed: Bool

    /// Why the most recent `accept` returned `nil`, for diagnostics. A
    /// suppressed observation is the hardest kind of status behaviour to
    /// explain from the outside ("the screen clearly says Ready for Review,
    /// so why is the card still Waiting?"), so the arbiter records its
    /// reasoning instead of discarding it silently.
    public private(set) var lastRejectionCause: String?

    /// - Parameter sessionHasProgressed: pass `true` when the session already
    ///   carries a persisted status, so a restored session that was genuinely
    ///   review-ready is not re-gated. A brand-new session (`nil` status)
    ///   passes `false`.
    public init(sessionHasProgressed: Bool = false) {
        self.sessionHasProgressed = sessionHasProgressed
    }

    public mutating func accept(
        _ observation: SessionStatusObservation,
        from source: Source
    ) -> SessionStatusObservation? {
        lastRejectionCause = nil
        if observation.status != .readyForReview {
            sessionHasProgressed = true
        }
        if source != .screen {
            latestStructuredObservation = observation
            return observation
        }

        if observation.status == .readyForReview,
           !sessionHasProgressed,
           latestStructuredObservation?.status != .readyForReview {
            lastRejectionCause = "screen readyForReview held back — session has shown no working or waiting signal yet"
            return nil
        }

        if observation.endsTurn {
            // The provider says the turn is over and no hook will follow.
            latestStructuredObservation = nil
            return observation
        }

        if let structured = latestStructuredObservation {
            if (structured.status == .working || structured.status == .waitingForInput),
               observation.status == .readyForReview {
                lastRejectionCause = "screen readyForReview outranked by pending structured status \(structured.status.rawValue)"
                    + (structured.waitingReason.map { "/\($0.rawValue)" } ?? "")
                return nil
            }
            if structured.status == .waitingForInput,
               observation.status == .waitingForInput,
               let structuredReason = structured.waitingReason,
               observation.waitingReason != structuredReason {
                lastRejectionCause = "screen waiting reason "
                    + (observation.waitingReason?.rawValue ?? "none")
                    + " disagrees with pending structured reason \(structuredReason.rawValue)"
                return nil
            }
        }

        // Visible work starts a newer episode after a prior terminal/waiting
        // hook. A confirming working screen deliberately retains a hook's
        // working hold: transient redraws can hide its marker, and only the
        // provider's terminal hook authoritatively ends that episode.
        if (observation.status == .working && latestStructuredObservation?.status != .working) ||
            observation.status == .crashed {
            latestStructuredObservation = nil
        }
        return observation
    }
}
