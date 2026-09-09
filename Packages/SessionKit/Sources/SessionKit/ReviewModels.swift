import Foundation

/// Which set of changes a review is looking at.
///
/// An agent working in a worktree commits as it goes, so neither view alone is
/// the whole story: `branch` is everything the session produced since it left
/// the base branch, `uncommitted` is only what is still sitting in the working
/// tree. Persisted because viewed-marks are recorded per scope — the same file
/// carries different diffs under each, and a mark earned against one says
/// nothing about the other.
public enum ReviewScope: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Everything on the branch versus its merge-base with the base branch,
    /// including uncommitted and untracked work.
    case branch
    /// Working-tree changes only: staged, unstaged, untracked.
    case uncommitted

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .branch: "All Branch Work"
        case .uncommitted: "Uncommitted"
        }
    }
}

/// The side of a diff a comment is attached to.
///
/// Deliberately its own type rather than GitKit's `DiffSide`: SessionKit is a
/// leaf package and the persisted vocabulary should not move when GitKit's
/// rendering types do. The app maps between them.
public enum ReviewSide: String, Codable, Hashable, Sendable {
    /// The file as it was — a comment on a line the agent deleted.
    case old
    /// The file as the agent left it — a comment on added or unchanged code.
    case new
}

/// What a review comment is about.
///
/// Anchored by line *number* rather than by position in the patch so a comment
/// survives the review refreshing its diff, which happens on every poll.
public enum ReviewCommentAnchor: Codable, Hashable, Sendable {
    /// The file as a whole.
    case file
    /// One line, on one side of the diff.
    case line(side: ReviewSide, number: Int)

    public var side: ReviewSide? {
        if case let .line(side, _) = self { return side }
        return nil
    }

    public var lineNumber: Int? {
        if case let .line(_, number) = self { return number }
        return nil
    }
}

/// A note the reviewer left for the agent.
public struct ReviewComment: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    /// The session whose work is under review.
    public var sessionID: UUID
    /// Repository-relative path, as git reports it.
    public var filePath: String
    public var anchor: ReviewCommentAnchor
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date
    /// When this comment was last delivered to an agent. `nil` while it is
    /// still a draft; a sent comment stays visible so the reviewer can see
    /// what was already asked for.
    public var sentAt: Date?

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        filePath: String,
        anchor: ReviewCommentAnchor,
        body: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sentAt: Date? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.filePath = filePath
        self.anchor = anchor
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sentAt = sentAt
    }

    public var isSent: Bool { sentAt != nil }
}

/// A file the reviewer has ticked off.
///
/// `diffFingerprint` is what makes the mark honest: the agent can keep working
/// during a review, and a file that changes after being marked viewed has not
/// been reviewed. A mark whose fingerprint no longer matches the diff on
/// screen reads as unviewed again.
public struct ReviewedFile: Codable, Hashable, Sendable {
    public var sessionID: UUID
    public var scope: ReviewScope
    public var filePath: String
    public var diffFingerprint: String
    public var viewedAt: Date

    public init(
        sessionID: UUID,
        scope: ReviewScope,
        filePath: String,
        diffFingerprint: String,
        viewedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.scope = scope
        self.filePath = filePath
        self.diffFingerprint = diffFingerprint
        self.viewedAt = viewedAt
    }
}
