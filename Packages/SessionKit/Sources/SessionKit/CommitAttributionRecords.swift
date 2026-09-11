import Foundation

/// What Flotilla keeps about an agent session to attribute its commits on this
/// Mac. A copy rather than a reference to `Session`: deleting a session must
/// not erase who made its commits.
public struct AttributionSessionSnapshot: Codable, Hashable, Sendable {
    public var sessionID: UUID
    public var projectID: UUID?
    /// The repository's shared git directory with symlinks resolved — the
    /// same for every worktree of one repository.
    public var repositoryKey: String
    public var agent: AgentKind
    /// The model picked at launch; `nil` means the agent's own default.
    public var model: String?
    public var title: String
    public var prompt: String
    /// `git patch-id` of everything the session committed, taken as one change
    /// — how a squash of the session's work is recognised later.
    public var combinedPatchID: String?
    public var createdAt: Date

    public init(
        sessionID: UUID,
        projectID: UUID?,
        repositoryKey: String,
        agent: AgentKind,
        model: String?,
        title: String,
        prompt: String,
        combinedPatchID: String?,
        createdAt: Date
    ) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.repositoryKey = repositoryKey
        self.agent = agent
        self.model = model
        self.title = title
        self.prompt = prompt
        self.combinedPatchID = combinedPatchID
        self.createdAt = createdAt
    }
}

/// One commit an agent session made, identified by what Git keeps when the
/// commit is rewritten rather than by its SHA.
public struct AttributedCommit: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var sessionID: UUID
    public var repositoryKey: String
    public var authorEmail: String
    /// Seconds since 1970. Rebase, cherry-pick and amend all preserve it.
    public var authorTime: Int
    public var patchID: String?
    public var originalSHA: String
    /// The agent and model at the time of the commit; a handoff can change
    /// either mid-session.
    public var agent: AgentKind
    public var model: String?
    public var recordedAt: Date

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        repositoryKey: String,
        authorEmail: String,
        authorTime: Int,
        patchID: String?,
        originalSHA: String,
        agent: AgentKind,
        model: String?,
        recordedAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.repositoryKey = repositoryKey
        self.authorEmail = authorEmail
        self.authorTime = authorTime
        self.patchID = patchID
        self.originalSHA = originalSHA
        self.agent = agent
        self.model = model
        self.recordedAt = recordedAt
    }
}

/// How a SHA came to be linked to an `AttributedCommit`.
public enum AttributedCommitLinkSource: String, Codable, Sendable {
    /// Reported by the hook when the commit was made.
    case recorded
    /// Reported by git's `post-rewrite` for an amend or rebase the agent ran.
    case rewrite
    /// Found by matching author email and time after a rewrite elsewhere.
    case authorTime
    /// A commit whose change equals the session's combined change.
    case squash
}

/// Where an `AttributedCommit` lives in history now. There can be several:
/// the original, a cherry-picked copy, the squash that absorbed it.
public struct AttributedCommitLink: Codable, Hashable, Sendable {
    public var commitID: UUID
    public var sha: String
    public var source: AttributedCommitLinkSource
    public var verifiedAt: Date

    public init(commitID: UUID, sha: String, source: AttributedCommitLinkSource, verifiedAt: Date) {
        self.commitID = commitID
        self.sha = sha
        self.source = source
        self.verifiedAt = verifiedAt
    }
}
