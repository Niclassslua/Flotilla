import Foundation
import SessionKit

/// The phone's view of one Flotilla session — what a fleet row and the session
/// header need, not the Mac's full `Session` record.
public struct CompanionSession: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var agent: AgentKind
    public var model: String
    public var effort: AgentEffort?
    /// `nil` until the agent produces its first signal ("Unstarted").
    public var status: SessionStatus?
    public var waitingReason: SessionWaitingReason?
    /// `nil` for a General session.
    public var projectID: UUID?
    public var branch: String?
    public var hasWorktree: Bool
    /// Whether the agent process is still alive. Drives the delete warning.
    public var isProcessLive: Bool
    public var updatedAt: Date
    public var diffStat: DiffStat?
    /// What the pending card asks for, in one line (`Allow rm -rf build?`).
    public var attentionSummary: String?
    /// A failed turn (quota, unknown model). Keeps the composer usable.
    public var failure: String?
    public var crashReason: String?
    /// Set once the diff is opened or a prompt is sent, which collapses the
    /// Ready-for-review card. Phone-local; the Mac always sends `false`.
    public var reviewAcknowledged: Bool
    /// Agents this session can be handed off to with its conversation.
    public var handoffTargets: [AgentKind]
    /// Whether the Mac can supply this session's transcript.
    public var hasTranscript: Bool

    public init(
        id: UUID,
        title: String,
        agent: AgentKind,
        model: String,
        effort: AgentEffort? = nil,
        status: SessionStatus? = nil,
        waitingReason: SessionWaitingReason? = nil,
        projectID: UUID? = nil,
        branch: String? = nil,
        hasWorktree: Bool,
        isProcessLive: Bool,
        updatedAt: Date,
        diffStat: DiffStat? = nil,
        attentionSummary: String? = nil,
        failure: String? = nil,
        crashReason: String? = nil,
        reviewAcknowledged: Bool = false,
        handoffTargets: [AgentKind] = [],
        hasTranscript: Bool = true
    ) {
        self.id = id
        self.title = title
        self.agent = agent
        self.model = model
        self.effort = effort
        self.status = status
        self.waitingReason = waitingReason
        self.projectID = projectID
        self.branch = branch
        self.hasWorktree = hasWorktree
        self.isProcessLive = isProcessLive
        self.updatedAt = updatedAt
        self.diffStat = diffStat
        self.attentionSummary = attentionSummary
        self.failure = failure
        self.crashReason = crashReason
        self.reviewAcknowledged = reviewAcknowledged
        self.handoffTargets = handoffTargets
        self.hasTranscript = hasTranscript
    }

    /// Pinned under **Needs you** in the fleet.
    public var needsYou: Bool {
        status == .waitingForInput || status == .crashed || failure != nil
    }
}

public struct DiffStat: Hashable, Codable, Sendable {
    public var files: Int
    public var additions: Int
    public var deletions: Int

    public init(files: Int, additions: Int, deletions: Int) {
        self.files = files
        self.additions = additions
        self.deletions = deletions
    }

    public var summary: String {
        "\(files) \(files == 1 ? "file" : "files") +\(additions) −\(deletions)"
    }
}

/// A project as the create-session picker needs it. The Mac's `Project` also
/// carries a filesystem path, which means nothing on the phone.
public struct ProjectSummary: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// Everything the fleet screen needs from one Mac, sent whole on every change.
public struct FleetSnapshot: Hashable, Codable, Sendable {
    public var macID: String
    public var macName: String
    public var sessions: [CompanionSession]
    public var projects: [ProjectSummary]
    public var catalog: AgentCatalog
    /// Sessions with a pending interaction the phone can answer.
    public var pending: [UUID: [PendingInteraction]]

    public init(
        macID: String,
        macName: String,
        sessions: [CompanionSession],
        projects: [ProjectSummary],
        catalog: AgentCatalog,
        pending: [UUID: [PendingInteraction]] = [:]
    ) {
        self.macID = macID
        self.macName = macName
        self.sessions = sessions
        self.projects = projects
        self.catalog = catalog
        self.pending = pending
    }
}

/// Revisioned change to a phone's last fleet. The order is explicit because
/// activity can reorder rows without changing any other session fields.
public struct FleetDelta: Hashable, Codable, Sendable {
    public var baseRevision: UInt64
    public var revision: UInt64
    public var orderedIDs: [UUID]
    public var changed: [CompanionSession]
    public var pendingChanges: [UUID: [PendingInteraction]]
    public var projects: [ProjectSummary]?
    public var catalog: AgentCatalog?
    public var macName: String?

    public static func make(from old: FleetSnapshot, to new: FleetSnapshot, baseRevision: UInt64) -> Self {
        let prior = Dictionary(uniqueKeysWithValues: old.sessions.map { ($0.id, $0) })
        let keys = Set(old.pending.keys).union(new.pending.keys)
        return Self(
            baseRevision: baseRevision, revision: baseRevision + 1,
            orderedIDs: new.sessions.map(\.id),
            changed: new.sessions.filter { prior[$0.id] != $0 },
            pendingChanges: Dictionary(uniqueKeysWithValues: keys.compactMap { id in
                let before = old.pending[id] ?? []
                let after = new.pending[id] ?? []
                return before == after ? nil : (id, after)
            }),
            projects: old.projects == new.projects ? nil : new.projects,
            catalog: old.catalog == new.catalog ? nil : new.catalog,
            macName: old.macName == new.macName ? nil : new.macName
        )
    }

    public func applying(to old: FleetSnapshot, revision currentRevision: UInt64) -> FleetSnapshot? {
        guard baseRevision == currentRevision, revision == baseRevision + 1 else { return nil }
        var result = old
        var byID = Dictionary(uniqueKeysWithValues: old.sessions.map { ($0.id, $0) })
        for session in changed { byID[session.id] = session }
        let ordered = orderedIDs.compactMap { byID[$0] }
        guard ordered.count == orderedIDs.count, Set(orderedIDs).count == orderedIDs.count else { return nil }
        let currentIDs = Set(orderedIDs)
        result.sessions = ordered
        for (id, cards) in pendingChanges {
            result.pending[id] = cards.isEmpty ? nil : cards
        }
        result.pending = result.pending.filter { currentIDs.contains($0.key) }
        if let projects { result.projects = projects }
        if let catalog { result.catalog = catalog }
        if let macName { result.macName = macName }
        return result
    }
}
