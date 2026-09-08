import Foundation
import os
import SessionKit

/// Where a status change came from — the "why" half of every trace line.
///
/// A status can be set by four very different mechanisms (a provider hook, the
/// terminal screen heuristic, the agent process exiting, or the user dragging a
/// card), and from the outside they are indistinguishable: the badge simply
/// says "Ready for Review". This type keeps the mechanism attached to the
/// change all the way to the log.
struct SessionStatusOrigin: Sendable {
    let label: String

    private init(_ label: String) {
        self.label = label
    }

    /// A hook event or screen reading that came through `HookCoordinator`.
    /// `cause` is the observation's own explanation (see
    /// `SessionStatusObservation.cause`).
    static func observation(source: String, cause: String?) -> Self {
        Self("\(source): \(cause ?? "no cause recorded")")
    }

    static func processExit(code: Int32) -> Self {
        Self("process exit code \(code)")
    }

    static let launch = Self("session launched")
    static let restart = Self("session restarted by user")
    static let resumeRetry = Self("resume failed — relaunched with fresh context")
    static func handoff(from source: AgentKind, to target: AgentKind) -> Self {
        Self("handed off from \(source.displayName) to \(target.displayName)")
    }
    static let handoffRollback = Self("handoff destination did not start — returned to the source agent")
    static let restoreFailed = Self("restore at app launch failed")
    static let boardMove = Self("user moved the card on the board")
    static let uiTestFixture = Self("UI-test fixture")
    /// A caller that did not say where the status came from. Should not appear
    /// in a normal run — if it does, a new status path needs an origin.
    static let unattributed = Self("unattributed caller")
}

/// Traces every status a session takes, and every status it was *asked* to
/// take and didn't.
///
/// Unlike `PerfLog` this is always on: status changes happen a handful of times
/// per session (the observation pipeline already filters level-signal repeats
/// before reaching `AppStore`), so the log stays readable, and the whole point
/// is to be able to explain a transition after the fact without having
/// reproduced it under a flag.
///
/// Read it live while working a session:
///
///     log stream --style compact --predicate 'subsystem == "com.niclassslua.flotilla" AND category == "SessionStatus"'
///
/// Or after the fact:
///
///     log show --last 30m --style compact --predicate 'subsystem == "com.niclassslua.flotilla" AND category == "SessionStatus"'
///
/// Applied changes are logged at `notice`, so they survive in the log store
/// without any extra flags. The noisier lines — observations that were
/// suppressed, and statuses the state machine refused — are `debug`/`info`,
/// which need `log stream --level debug` to see.
enum SessionStatusTrace {
    static let logger = Logger(subsystem: "com.niclassslua.flotilla", category: "SessionStatus")

    /// A status change that actually landed on the session.
    static func applied(
        sessionID: UUID,
        title: String,
        from previous: SessionStatus?,
        fromReason previousReason: SessionWaitingReason?,
        to next: SessionStatus,
        toReason nextReason: SessionWaitingReason?,
        origin: SessionStatusOrigin
    ) {
        logger.notice(
            """
            \(shortID(sessionID), privacy: .public) \(title, privacy: .public) \
            \(describe(previous, previousReason), privacy: .public) → \(describe(next, nextReason), privacy: .public) \
            — \(origin.label, privacy: .public)
            """
        )
    }

    /// A status that was requested but changed nothing: either the session was
    /// already in it, or `SessionStatusMachine` refused the transition.
    static func ignored(
        sessionID: UUID,
        title: String,
        current: SessionStatus?,
        currentReason: SessionWaitingReason?,
        requested: SessionStatus,
        origin: SessionStatusOrigin,
        detail: String
    ) {
        logger.info(
            """
            \(shortID(sessionID), privacy: .public) \(title, privacy: .public) \
            stayed \(describe(current, currentReason), privacy: .public), \
            asked for \(requested.rawValue, privacy: .public) — \(detail, privacy: .public) \
            (\(origin.label, privacy: .public))
            """
        )
    }

    /// An observation the arbiter dropped before `AppStore` ever saw it — the
    /// case where the screen says one thing and a still-standing hook event
    /// says another.
    static func suppressed(
        sessionID: UUID,
        source: String,
        observation: String,
        reason: String
    ) {
        logger.debug(
            """
            \(shortID(sessionID), privacy: .public) suppressed \(source, privacy: .public) \
            \(observation, privacy: .public) — \(reason, privacy: .public)
            """
        )
    }

    /// Every observation that reached `HookCoordinator`, before arbitration.
    /// The most granular level: this is what to turn to when a status looks
    /// right in the log but wrong on screen.
    static func observed(sessionID: UUID, source: String, observation: String) {
        logger.debug(
            "\(shortID(sessionID), privacy: .public) observed \(source, privacy: .public) \(observation, privacy: .public)"
        )
    }

    /// Full UUIDs make every line wrap in a terminal; the first component is
    /// unique enough to follow one session through a log and still greppable
    /// against a full ID.
    private static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    private static func describe(_ status: SessionStatus?, _ reason: SessionWaitingReason?) -> String {
        guard let status else { return "none" }
        guard let reason else { return status.rawValue }
        return "\(status.rawValue)/\(reason.rawValue)"
    }
}
