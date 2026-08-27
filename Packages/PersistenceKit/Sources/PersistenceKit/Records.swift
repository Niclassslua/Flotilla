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

    var errorDescription: String? {
        switch self {
        case .invalidProjectID(let value):
            "Stored project has an invalid identifier: \(value)"
        case let .invalidSession(id, field, value):
            "Stored session \(id) has an invalid \(field): \(value)"
        case let .invalidKanbanBoard(id, field, value):
            "Stored kanban board \(id) has an invalid \(field): \(value)"
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
