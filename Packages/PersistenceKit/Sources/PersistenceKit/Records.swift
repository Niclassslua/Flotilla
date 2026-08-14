import Foundation
import GRDB
import SessionKit

enum RecordDecodingError: LocalizedError {
    case invalidProjectID(String)
    case invalidSession(id: String, field: String, value: String)

    var errorDescription: String? {
        switch self {
        case .invalidProjectID(let value):
            "Stored project has an invalid identifier: \(value)"
        case let .invalidSession(id, field, value):
            "Stored session \(id) has an invalid \(field): \(value)"
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
    var projectID: String?
    var workingDirectory: String
    var worktreeBranchName: String?
    var worktreePath: String?
    var worktreeBaseCheckoutPath: String?
    var status: String
    var terminalScrollback: Data
    var createdAt: Date
    var lastActiveAt: Date

    init(session: Session) {
        id = session.id.uuidString
        title = session.title
        goal = session.goal
        agent = session.agent.rawValue
        projectID = session.projectID?.uuidString
        workingDirectory = session.workingDirectory.path
        worktreeBranchName = session.worktree?.branchName
        worktreePath = session.worktree?.worktreePath.path
        worktreeBaseCheckoutPath = session.worktree?.baseCheckoutPath.path
        status = session.status.rawValue
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
        guard let sessionStatus = SessionStatus(rawValue: status) else {
            throw RecordDecodingError.invalidSession(id: id, field: "status", value: status)
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

        return Session(
            id: uuid,
            title: title,
            goal: goal,
            agent: agentKind,
            projectID: projectUUID,
            workingDirectory: URL(fileURLWithPath: workingDirectory),
            worktree: worktree,
            status: sessionStatus,
            terminalScrollback: terminalScrollback,
            createdAt: createdAt,
            lastActiveAt: lastActiveAt
        )
    }
}
