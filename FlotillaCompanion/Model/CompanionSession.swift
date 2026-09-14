import Foundation
import SessionKit

/// The phone's view of one Flotilla session — what a fleet row and the session
/// header need, not the Mac's full `Session` record.
struct CompanionSession: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var agent: AgentKind
    var model: String
    var effort: AgentEffort?
    /// `nil` until the agent produces its first signal ("Unstarted").
    var status: SessionStatus?
    var waitingReason: SessionWaitingReason?
    /// `nil` for a General session.
    var projectID: UUID?
    var branch: String?
    var hasWorktree: Bool
    /// Whether the agent process is still alive. Drives the delete warning.
    var isProcessLive: Bool
    var updatedAt: Date
    var diffStat: DiffStat?
    /// What the pending card asks for, in one line (`Allow rm -rf build?`).
    var attentionSummary: String?
    /// A failed turn (quota, unknown model). Keeps the composer usable.
    var failure: String?
    var crashReason: String?
    /// Set once the diff is opened or a prompt is sent, which collapses the
    /// Ready-for-review card.
    var reviewAcknowledged = false

    /// Pinned under **Needs you** in the fleet.
    var needsYou: Bool {
        status == .waitingForInput || status == .crashed || failure != nil
    }
}

struct DiffStat: Hashable, Sendable {
    var files: Int
    var additions: Int
    var deletions: Int

    var summary: String {
        "\(files) \(files == 1 ? "file" : "files") +\(additions) −\(deletions)"
    }
}

/// A project as the create-session picker needs it. The Mac's `Project` also
/// carries a filesystem path, which means nothing on the phone.
struct ProjectSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
}
