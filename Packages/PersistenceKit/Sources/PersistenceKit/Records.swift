import Foundation
import GRDB
import SessionKit

public extension SessionStatus {
    /// Decodes a persisted status string, folding the pre-collapse values
    /// `idle`, `finished`, and `ready` into `readyForReview`. Returns `nil`
    /// for an unrecognised value; an empty string ("no status yet") is
    /// handled by callers before this is reached.
    static func parseLegacy(rawValue: String) -> SessionStatus? {
        switch rawValue {
        case "idle", "finished", "ready":
            return .readyForReview
        default:
            return SessionStatus(rawValue: rawValue)
        }
    }
}

enum RecordDecodingError: LocalizedError {
    case invalidProjectID(String)
    case invalidSession(id: String, field: String, value: String)
    case invalidKanbanBoard(id: String, field: String, value: String)
    case invalidReviewComment(id: String, field: String, value: String)

    var errorDescription: String? {
        switch self {
        case .invalidProjectID(let value):
            "Stored project has an invalid identifier: \(value)"
        case let .invalidSession(id, field, value):
            "Stored session \(id) has an invalid \(field): \(value)"
        case let .invalidKanbanBoard(id, field, value):
            "Stored kanban board \(id) has an invalid \(field): \(value)"
        case let .invalidReviewComment(id, field, value):
            "Stored review comment \(id) has an invalid \(field): \(value)"
        }
    }
}

/// GRDB row DTOs, kept separate from the SessionKit domain structs so the
/// domain layer stays persistence-agnostic (no URL/enum-as-DatabaseValue
/// coupling, no retroactive GRDB conformances on someone else's types).
struct ProjectRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "project"

    var id: String
    var name: String
    var rootPath: String

    init(project: Project) {
        id = project.id.uuidString
        name = project.name
        rootPath = project.rootPath.path
    }

    func toDomain() throws -> Project {
        guard let uuid = UUID(uuidString: id) else {
            throw RecordDecodingError.invalidProjectID(id)
        }
        return Project(id: uuid, name: name, rootPath: URL(fileURLWithPath: rootPath))
    }
}

struct SessionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "session"

    var id: String
    var title: String
    var goal: String
    var agent: String
    var model: String?
    var effort: String?
    var projectID: String?
    var workingDirectory: String
    var worktreeBranchName: String?
    var worktreePath: String?
    var worktreeBaseCheckoutPath: String?
    var status: String
    var waitingReason: String?
    var kanbanColumnID: String?
    var workflowStage: String?
    var agentSessionID: String?
    var nativeTranscriptPath: String?
    var handoffSourceAgent: String?
    var handoffSourceSessionID: String?
    var handoffSourceTranscriptPath: String?
    var handoffSourceModel: String?
    var handoffSourceEffort: String?
    var handoffStartedAt: Date?
    var terminalScrollback: Data
    var createdAt: Date
    var lastActiveAt: Date

    init(session: Session) {
        id = session.id.uuidString
        title = session.title
        goal = session.goal
        agent = session.agent.rawValue
        model = session.model
        effort = session.effort?.rawValue
        projectID = session.projectID?.uuidString
        workingDirectory = session.workingDirectory.path
        worktreeBranchName = session.worktree?.branchName
        worktreePath = session.worktree?.worktreePath.path
        worktreeBaseCheckoutPath = session.worktree?.baseCheckoutPath.path
        status = session.status?.rawValue ?? ""
        waitingReason = session.waitingReason?.rawValue
        kanbanColumnID = session.kanbanColumnID?.uuidString
        workflowStage = session.workflowStage?.rawValue
        agentSessionID = session.agentSessionID
        nativeTranscriptPath = session.nativeTranscriptPath?.path
        handoffSourceAgent = session.pendingHandoff?.sourceAgent.rawValue
        handoffSourceSessionID = session.pendingHandoff?.sourceSessionID
        handoffSourceTranscriptPath = session.pendingHandoff?.sourceTranscriptPath.path
        handoffSourceModel = session.pendingHandoff?.sourceModel
        handoffSourceEffort = session.pendingHandoff?.sourceEffort?.rawValue
        handoffStartedAt = session.pendingHandoff?.startedAt
        terminalScrollback = session.terminalScrollback
        createdAt = session.createdAt
        lastActiveAt = session.lastActiveAt
    }

    func toDomain() throws -> Session {
        guard let uuid = UUID(uuidString: id) else {
            throw RecordDecodingError.invalidSession(id: id, field: "identifier", value: id)
        }
        guard let agentKind = AgentKind(rawValue: agent) else {
            throw RecordDecodingError.invalidSession(id: id, field: "agent", value: agent)
        }
        // An empty string is a session with no status yet (`nil`). Legacy
        // `idle` / `finished` / `ready` fold into `readyForReview`. Anything
        // else that is non-empty and unrecognised is a real decode error.
        let sessionStatus: SessionStatus?
        if status.isEmpty {
            sessionStatus = nil
        } else if let parsed = SessionStatus.parseLegacy(rawValue: status) {
            sessionStatus = parsed
        } else {
            throw RecordDecodingError.invalidSession(id: id, field: "status", value: status)
        }
        let sessionWaitingReason: SessionWaitingReason?
        if let waitingReason {
            guard let parsedWaitingReason = SessionWaitingReason(rawValue: waitingReason) else {
                throw RecordDecodingError.invalidSession(id: id, field: "waiting reason", value: waitingReason)
            }
            sessionWaitingReason = parsedWaitingReason
        } else {
            sessionWaitingReason = nil
        }
        let sessionEffort: AgentEffort?
        if let effort {
            guard let parsedEffort = AgentEffort(rawValue: effort) else {
                throw RecordDecodingError.invalidSession(id: id, field: "effort", value: effort)
            }
            sessionEffort = parsedEffort
        } else {
            sessionEffort = nil
        }
        let projectUUID: UUID?
        if let projectID {
            guard let parsed = UUID(uuidString: projectID) else {
                throw RecordDecodingError.invalidSession(id: id, field: "project identifier", value: projectID)
            }
            projectUUID = parsed
        } else {
            projectUUID = nil
        }

        var worktree: WorktreeInfo?
        if let branch = worktreeBranchName, let path = worktreePath, let base = worktreeBaseCheckoutPath {
            worktree = WorktreeInfo(
                branchName: branch,
                worktreePath: URL(fileURLWithPath: path),
                baseCheckoutPath: URL(fileURLWithPath: base)
            )
        }

        let kanbanColumnUUID: UUID?
        if let kanbanColumnID {
            kanbanColumnUUID = UUID(uuidString: kanbanColumnID)
        } else {
            kanbanColumnUUID = nil
        }

        let workflowStageValue: WorkflowStage?
        if let workflowStage {
            workflowStageValue = WorkflowStage(rawValue: workflowStage)
        } else {
            workflowStageValue = nil
        }

        // A pending handoff is only meaningful with all three parts; a row
        // carrying some but not others is a half-written probation record and
        // is treated as no handoff in flight.
        let pending: PendingHandoff?
        if let handoffSourceAgent,
           let sourceAgent = AgentKind(rawValue: handoffSourceAgent),
           let handoffSourceSessionID,
           let handoffSourceTranscriptPath,
           let handoffStartedAt {
            pending = PendingHandoff(
                sourceAgent: sourceAgent,
                sourceSessionID: handoffSourceSessionID,
                sourceTranscriptPath: URL(fileURLWithPath: handoffSourceTranscriptPath),
                sourceModel: handoffSourceModel,
                sourceEffort: handoffSourceEffort.flatMap(AgentEffort.init(rawValue:)),
                startedAt: handoffStartedAt
            )
        } else {
            pending = nil
        }

        return Session(
            id: uuid,
            title: title,
            goal: goal,
            agent: agentKind,
            model: model,
            effort: sessionEffort,
            projectID: projectUUID,
            workingDirectory: URL(fileURLWithPath: workingDirectory),
            worktree: worktree,
            status: sessionStatus,
            waitingReason: sessionWaitingReason,
            kanbanColumnID: kanbanColumnUUID,
            workflowStage: workflowStageValue,
            agentSessionID: agentSessionID,
            nativeTranscriptPath: nativeTranscriptPath.map { URL(fileURLWithPath: $0) },
            pendingHandoff: pending,
            terminalScrollback: terminalScrollback,
            createdAt: createdAt,
            lastActiveAt: lastActiveAt
        )
    }
}

struct KanbanColumnRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "kanban_column"

    var id: String
    var boardID: String
    var title: String
    var order: Int
    var statusFilter: String?
    var agentFilter: String?
    var workflowStageFilter: String?
    var color: String?

    init(column: KanbanColumn, boardID: UUID) {
        self.id = column.id.uuidString
        self.boardID = boardID.uuidString
        self.title = column.title
        self.order = column.order
        self.statusFilter = column.statusFilter?.rawValue
        self.agentFilter = column.agentFilter?.rawValue
        self.workflowStageFilter = column.workflowStageFilter?.rawValue
        self.color = column.color
    }

    func toDomain() -> KanbanColumn {
        return KanbanColumn(
            id: UUID(uuidString: id) ?? UUID(),
            title: title,
            order: order,
            statusFilter: statusFilter.flatMap(SessionStatus.parseLegacy(rawValue:)),
            agentFilter: agentFilter.flatMap(AgentKind.init(rawValue:)),
            workflowStageFilter: workflowStageFilter.flatMap(WorkflowStage.init(rawValue:)),
            color: color
        )
    }
}

struct KanbanBoardRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "kanban_board"

    var id: String
    var projectID: String?
    var name: String
    var columnMode: String
    var customColumnsJSON: String
    var cardOrderJSON: String
    var updatedAt: Date

    init(board: KanbanBoard) {
        id = board.id.uuidString
        projectID = board.projectID?.uuidString
        name = board.name
        columnMode = board.columnMode.rawValue
        // Encode custom columns and card order as JSON
        let encoder = JSONEncoder()
        customColumnsJSON = (try? String(data: encoder.encode(board.customColumns), encoding: .utf8)) ?? "[]"
        cardOrderJSON = (try? String(data: encoder.encode(board.cardOrder), encoding: .utf8)) ?? "{}"
        updatedAt = board.updatedAt
    }

    func toDomain() throws -> KanbanBoard {
        guard let uuid = UUID(uuidString: id) else {
            throw RecordDecodingError.invalidKanbanBoard(id: id, field: "identifier", value: id)
        }
        guard let mode = KanbanColumnMode(rawValue: columnMode) else {
            throw RecordDecodingError.invalidKanbanBoard(id: id, field: "columnMode", value: columnMode)
        }
        let projectUUID: UUID?
        if let projectID {
            guard let parsed = UUID(uuidString: projectID) else {
                throw RecordDecodingError.invalidKanbanBoard(id: id, field: "project identifier", value: projectID)
            }
            projectUUID = parsed
        } else {
            projectUUID = nil
        }

        let decoder = JSONDecoder()
        let customColumns = (try? decoder.decode([KanbanColumn].self, from: Data(customColumnsJSON.utf8))) ?? []
        let cardOrder = (try? decoder.decode([String: Int].self, from: Data(cardOrderJSON.utf8))) ?? [:]

        return KanbanBoard(
            id: uuid,
            projectID: projectUUID,
            name: name,
            columnMode: mode,
            customColumns: customColumns,
            cardOrder: cardOrder,
            updatedAt: updatedAt
        )
    }
}

// MARK: - Review

struct ReviewCommentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "review_comment"

    var id: String
    var sessionID: String
    var filePath: String
    /// `nil` for a whole-file comment; otherwise the `ReviewSide` raw value.
    /// Stored as two nullable columns rather than an encoded blob so a line
    /// comment stays queryable by file and line.
    var anchorSide: String?
    var anchorLine: Int?
    var body: String
    var createdAt: Date
    var updatedAt: Date
    var sentAt: Date?

    init(comment: ReviewComment) {
        id = comment.id.uuidString
        sessionID = comment.sessionID.uuidString
        filePath = comment.filePath
        switch comment.anchor {
        case .file:
            anchorSide = nil
            anchorLine = nil
        case let .line(side, number):
            anchorSide = side.rawValue
            anchorLine = number
        }
        body = comment.body
        createdAt = comment.createdAt
        updatedAt = comment.updatedAt
        sentAt = comment.sentAt
    }

    func toDomain() throws -> ReviewComment {
        guard let uuid = UUID(uuidString: id) else {
            throw RecordDecodingError.invalidReviewComment(id: id, field: "identifier", value: id)
        }
        guard let session = UUID(uuidString: sessionID) else {
            throw RecordDecodingError.invalidReviewComment(id: id, field: "sessionID", value: sessionID)
        }

        let anchor: ReviewCommentAnchor
        switch (anchorSide, anchorLine) {
        case (nil, nil):
            anchor = .file
        case let (rawSide?, line?):
            guard let side = ReviewSide(rawValue: rawSide) else {
                throw RecordDecodingError.invalidReviewComment(id: id, field: "anchorSide", value: rawSide)
            }
            anchor = .line(side: side, number: line)
        default:
            // Half an anchor is not an anchor: one column set without the
            // other means the row was written by something that did not
            // understand the pair.
            throw RecordDecodingError.invalidReviewComment(
                id: id,
                field: "anchor",
                value: "side=\(anchorSide ?? "nil") line=\(anchorLine.map(String.init) ?? "nil")"
            )
        }

        return ReviewComment(
            id: uuid,
            sessionID: session,
            filePath: filePath,
            anchor: anchor,
            body: body,
            createdAt: createdAt,
            updatedAt: updatedAt,
            sentAt: sentAt
        )
    }
}

struct ReviewedFileRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "review_viewed_file"

    /// Keyed on `(sessionID, scope, filePath)`, so re-viewing a file replaces
    /// its fingerprint instead of adding a second row.
    static let persistenceConflictPolicy = PersistenceConflictPolicy(insert: .replace, update: .replace)

    var sessionID: String
    var scope: String
    var filePath: String
    var diffFingerprint: String
    var viewedAt: Date

    init(file: ReviewedFile) {
        sessionID = file.sessionID.uuidString
        scope = file.scope.rawValue
        filePath = file.filePath
        diffFingerprint = file.diffFingerprint
        viewedAt = file.viewedAt
    }

    /// Returns `nil` for a row whose session or scope no longer parses, rather
    /// than throwing: a viewed-mark is an optimisation, and losing one must
    /// not fail the whole review load.
    func toDomain() -> ReviewedFile? {
        guard let session = UUID(uuidString: sessionID),
              let scope = ReviewScope(rawValue: scope)
        else { return nil }
        return ReviewedFile(
            sessionID: session,
            scope: scope,
            filePath: filePath,
            diffFingerprint: diffFingerprint,
            viewedAt: viewedAt
        )
    }
}

// MARK: - Commit attribution

/// Attribution rows decode to `nil` rather than throwing when they no longer
/// parse: attribution is informational, and one bad row must not hide every
/// other commit's.
struct AttributionSessionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "attribution_session"

    var sessionID: String
    var projectID: String?
    var repositoryKey: String
    var agent: String
    var model: String?
    var title: String
    var prompt: String
    var combinedPatchID: String?
    var createdAt: Date

    init(snapshot: AttributionSessionSnapshot) {
        sessionID = snapshot.sessionID.uuidString
        projectID = snapshot.projectID?.uuidString
        repositoryKey = snapshot.repositoryKey
        agent = snapshot.agent.rawValue
        model = snapshot.model
        title = snapshot.title
        prompt = snapshot.prompt
        combinedPatchID = snapshot.combinedPatchID
        createdAt = snapshot.createdAt
    }

    func toDomain() -> AttributionSessionSnapshot? {
        guard let session = UUID(uuidString: sessionID),
              let agentKind = AgentKind(rawValue: agent)
        else { return nil }
        return AttributionSessionSnapshot(
            sessionID: session,
            projectID: projectID.flatMap(UUID.init(uuidString:)),
            repositoryKey: repositoryKey,
            agent: agentKind,
            model: model,
            title: title,
            prompt: prompt,
            combinedPatchID: combinedPatchID,
            createdAt: createdAt
        )
    }
}

struct AttributedCommitRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "attributed_commit"

    var id: String
    var sessionID: String
    var repositoryKey: String
    var authorEmail: String
    var authorTime: Int
    var patchID: String?
    var originalSHA: String
    var agent: String
    var model: String?
    var recordedAt: Date

    init(commit: AttributedCommit) {
        id = commit.id.uuidString
        sessionID = commit.sessionID.uuidString
        repositoryKey = commit.repositoryKey
        authorEmail = commit.authorEmail
        authorTime = commit.authorTime
        patchID = commit.patchID
        originalSHA = commit.originalSHA
        agent = commit.agent.rawValue
        model = commit.model
        recordedAt = commit.recordedAt
    }

    func toDomain() -> AttributedCommit? {
        guard let identifier = UUID(uuidString: id),
              let session = UUID(uuidString: sessionID),
              let agentKind = AgentKind(rawValue: agent)
        else { return nil }
        return AttributedCommit(
            id: identifier,
            sessionID: session,
            repositoryKey: repositoryKey,
            authorEmail: authorEmail,
            authorTime: authorTime,
            patchID: patchID,
            originalSHA: originalSHA,
            agent: agentKind,
            model: model,
            recordedAt: recordedAt
        )
    }
}

struct AttributedCommitLinkRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "attributed_commit_link"

    /// Keyed on `(commitID, sha)`. A repeated link keeps the source it was
    /// first found by, so a recorded commit never reads as a guessed one.
    static let persistenceConflictPolicy = PersistenceConflictPolicy(insert: .ignore, update: .replace)

    var commitID: String
    var sha: String
    var source: String
    var verifiedAt: Date

    init(link: AttributedCommitLink) {
        commitID = link.commitID.uuidString
        sha = link.sha
        source = link.source.rawValue
        verifiedAt = link.verifiedAt
    }

    func toDomain() -> AttributedCommitLink? {
        guard let commit = UUID(uuidString: commitID),
              let linkSource = AttributedCommitLinkSource(rawValue: source)
        else { return nil }
        return AttributedCommitLink(commitID: commit, sha: sha, source: linkSource, verifiedAt: verifiedAt)
    }
}
