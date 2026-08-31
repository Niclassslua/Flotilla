import Foundation
import SessionKit

/// A standing question about the fleet, answerable at a glance from the
/// navigator: *which agents need me, which are busy, which are done?*
///
/// Kept as three separate lists rather than one "needs attention" count
/// because they are three different decisions. Collapsing them would hide
/// which one you are being asked to make — see `docs/ui-model.md` § 2.
enum FleetSmartList: String, CaseIterable, Identifiable, Codable, Sendable {
    case needsYou
    case working
    case ready

    var id: Self { self }

    var title: String {
        switch self {
        case .needsYou: "Needs You"
        case .working: "Working"
        case .ready: "Ready"
        }
    }

    var systemImage: String {
        switch self {
        case .needsYou: "exclamationmark.circle"
        case .working: "gearshape.2"
        case .ready: "checkmark.circle"
        }
    }

    /// `needsYou` deliberately spans two statuses: a crashed agent and a
    /// blocked one both need a human, and `HomeContext.attentionSessions`
    /// already groups them that way. The distinction survives in each row's
    /// own status word — it is not lost, just not made into a fourth list.
    func matches(_ session: Session) -> Bool {
        switch self {
        case .needsYou: session.status == .waitingForInput || session.status == .crashed
        case .working: session.status == .working
        case .ready: session.status == .readyForReview
        }
    }

    func filter(_ sessions: [Session]) -> [Session] {
        sessions.filter(matches)
    }
}

/// Which slice of the fleet a group chip stands for.
///
/// Three states, not an optional project ID: `nil` already means "every
/// project" and so cannot also mean "the sessions belonging to no project".
/// General sessions (`projectID == nil`) are an ordinary, shipping case —
/// they need a group of their own, not the absence of one.
enum SessionGroup: Hashable, Codable, Sendable {
    case all
    case project(UUID)
    /// Sessions with no `projectID` — see `Session.projectID`.
    case general

    /// The persisted spelling in `WorkspacePreferences.sessionGroup`.
    var rawValue: String {
        switch self {
        case .all: "all"
        case .general: "general"
        case .project(let id): id.uuidString
        }
    }

    /// Unknown strings decode to `.all` rather than failing: a persisted
    /// group naming a project that has since been removed should drop the
    /// user into the whole fleet, not into an empty screen.
    init(rawValue: String) {
        switch rawValue {
        case "all": self = .all
        case "general": self = .general
        default: self = UUID(uuidString: rawValue).map(Self.project) ?? .all
        }
    }

    var projectID: UUID? {
        if case .project(let id) = self { return id }
        return nil
    }
}

/// What subset of the fleet a collection surface is rendering.
///
/// One value rather than a handful of loose parameters, so Grid, Board and
/// Focus cannot disagree about what they are showing: switching presentation
/// changes *how*, never *what*.
///
/// The two axes compose. A smart list comes from the navigator's selection, a
/// group from the session group bar, and "this project's agents that need me"
/// is both at once.
struct SessionScope: Equatable, Sendable {
    /// Limits to one project's sessions, or to the general ones.
    var group: SessionGroup = .all
    var smartList: FleetSmartList?

    static let everything = SessionScope()

    var isEverything: Bool { group == .all && smartList == nil }

    func apply(to sessions: [Session]) -> [Session] {
        var result = sessions
        switch group {
        case .all:
            break
        case .project(let id):
            result = result.filter { $0.projectID == id }
        case .general:
            result = result.filter { $0.projectID == nil }
        }
        if let smartList {
            result = smartList.filter(result)
        }
        return result
    }

    /// Shown when the scope renders nothing, so the empty state can say which
    /// narrowing is responsible rather than "no sessions".
    var emptyDescription: String {
        switch (group, smartList) {
        case (.all, nil): "Launch a session to get started."
        case (.all, .some(let list)): "No sessions are \(list.title.lowercased()) right now."
        case (.project, nil): "This project has no sessions yet."
        case (.project, .some(let list)): "No sessions in this project are \(list.title.lowercased())."
        case (.general, nil): "No sessions are running outside a project."
        case (.general, .some(let list)): "No sessions outside a project are \(list.title.lowercased())."
        }
    }
}
