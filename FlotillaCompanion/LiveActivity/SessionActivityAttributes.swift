import ActivityKit
import Foundation

/// Shared between FlotillaCompanion and
/// FlotillaCompanionWidget — the app starts/updates/ends the activity, the
/// widget extension renders it. Kept intentionally small: just enough for
/// the Dynamic Island and Lock Screen to show what's happening.
///
/// Local-only. See docs/companion.md decision #6: no push means this only
/// updates while the app is open, same limit as Smart Presence (Phase 5).
public struct SessionActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var statusLabel: String
        /// A stable color name (not `Color`, which isn't Codable the way
        /// ActivityKit needs) — the widget resolves it back via
        /// `StatusPresentation`-equivalent switch.
        public var statusKind: StatusKind
        public var startedAt: Date

        public init(statusLabel: String, statusKind: StatusKind, startedAt: Date) {
            self.statusLabel = statusLabel
            self.statusKind = statusKind
            self.startedAt = startedAt
        }
    }

    public enum StatusKind: String, Codable, Sendable {
        case working
        case waitingForInput
        case readyForReview
        case crashed
    }

    public var title: String
    public var agentDisplayName: String

    public init(title: String, agentDisplayName: String) {
        self.title = title
        self.agentDisplayName = agentDisplayName
    }
}
