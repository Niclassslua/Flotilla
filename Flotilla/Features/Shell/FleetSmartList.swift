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

/// What subset of the fleet a collection surface is rendering.
///
/// One value rather than a handful of loose parameters, so Grid, Board and
/// Focus cannot disagree about what they are showing: switching presentation
/// changes *how*, never *what*. U4 extends this with the composable status /
/// agent / project filters; the shape is the same.
struct SessionScope: Equatable, Sendable {
    /// Limits to one project's sessions. Independent of `smartList` — both
    /// can apply at once ("this repo's agents that need me").
    var projectID: UUID?
    var smartList: FleetSmartList?

    static let everything = SessionScope()

    var isEverything: Bool { projectID == nil && smartList == nil }

    func apply(to sessions: [Session]) -> [Session] {
        var result = sessions
        if let projectID {
            result = result.filter { $0.projectID == projectID }
        }
        if let smartList {
            result = smartList.filter(result)
        }
        return result
    }

    /// Shown when the scope renders nothing, so the empty state can say which
    /// narrowing is responsible rather than "no sessions".
    var emptyDescription: String {
        switch (projectID, smartList) {
        case (nil, nil): "Launch a session to get started."
        case (nil, .some(let list)): "No sessions are \(list.title.lowercased()) right now."
        case (.some, nil): "This project has no sessions yet."
        case (.some, .some(let list)): "No sessions in this project are \(list.title.lowercased())."
        }
    }
}
