import ActivityKit
import Foundation
import SessionKit

/// Shared between FlotillaCompanion and FlotillaCompanionWidget — the app
/// starts/updates/ends the activity, the widget extension renders it.
///
/// One activity for a Mac's whole fleet ("Fleet Radar"): who's busy, who's
/// blocked. Local-only. See docs/companion.md decision #6: no push means
/// this only updates while the app is open; `isLive` tells the widget when
/// it's showing a frozen snapshot instead.
public struct FleetActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        /// Most urgent first, capped at `FleetActivityAttributes.maxSessions`
        /// so the payload stays well under ActivityKit's 4 KB limit.
        public var sessions: [Session]
        /// Every session in the activity, including those past the cap.
        public var activeCount: Int
        /// False once the phone stops hearing from the Mac (the app went to
        /// the background, or the Mac dropped off): times stop ticking and
        /// the widget says when the snapshot was taken.
        public var isLive: Bool
        public var updatedAt: Date

        public init(sessions: [Session], activeCount: Int, isLive: Bool, updatedAt: Date) {
            self.sessions = sessions
            self.activeCount = activeCount
            self.isLive = isLive
            self.updatedAt = updatedAt
        }

        public var needsYouCount: Int { sessions.filter(\.status.needsYou).count }
        public var workingCount: Int { sessions.filter { $0.status == .working }.count }
    }

    public struct Session: Codable, Hashable, Sendable, Identifiable {
        public var id: UUID
        public var title: String
        public var agent: AgentKind
        public var status: Status
        /// One line under the title: the pending question, the crash
        /// reason, or the branch being worked on.
        public var detail: String
        /// When the session entered `status`.
        public var since: Date

        public init(id: UUID, title: String, agent: AgentKind, status: Status, detail: String, since: Date) {
            self.id = id
            self.title = title
            self.agent = agent
            self.status = status
            self.detail = detail
            self.since = since
        }
    }

    /// `SessionStatus` folded down to what the activity distinguishes.
    public enum Status: String, Codable, Sendable {
        /// Waiting for input, or a failed turn.
        case waiting
        case crashed
        case working
        case ready

        public var needsYou: Bool { self == .waiting || self == .crashed }
    }

    public static let maxSessions = 8

    public var macID: String
    public var macName: String

    public init(macID: String, macName: String) {
        self.macID = macID
        self.macName = macName
    }
}

/// Deep links the activity opens, handled by `RootView.onOpenURL`.
public enum FleetActivityLink {
    public static let scheme = "flotilla"

    public static func session(_ id: UUID) -> URL {
        URL(string: "\(scheme)://session/\(id.uuidString)")!
    }

    public static func fleet(_ macID: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "fleet"
        components.path = "/" + macID
        return components.url!
    }
}
