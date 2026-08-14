import Foundation
import GRDB
import SessionKit

/// GRDB-backed `SessionRepository`. On open, if the database file exists but
/// fails to open/migrate (corruption, truncation, foreign format), it's
/// moved aside with a timestamped suffix and a fresh database is created —
/// the app always launches, never blocked by a bad state file.
public final class GRDBSessionRepository: SessionRepository, @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    public let recoveredFromCorruption: Bool

    /// Disk-backed store at `path`, with corruption recovery.
    public init(path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if let queue = try? Self.openAndMigrate(at: path) {
            dbQueue = queue
            recoveredFromCorruption = false
        } else {
            let corruptPath = path.appendingPathExtension("corrupt-\(UUID().uuidString)")
            if FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.moveItem(at: path, to: corruptPath)
            }
            dbQueue = try Self.openAndMigrate(at: path)
            recoveredFromCorruption = true
        }
    }

    /// In-memory store — used by unit tests and `UI_TESTING=1` runs.
    public init() throws {
        dbQueue = try DatabaseQueue()
        try Self.migrator.migrate(dbQueue)
        recoveredFromCorruption = false
    }

    private static func openAndMigrate(at path: URL) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: path.path)
        try migrator.migrate(queue)
        return queue
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_createSessionAndProject") { db in
            try db.create(table: "project") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("rootPath", .text).notNull()
            }
            try db.create(table: "session") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("goal", .text).notNull()
                t.column("agent", .text).notNull()
                t.column("projectID", .text)
                t.column("workingDirectory", .text).notNull()
                t.column("worktreeBranchName", .text)
                t.column("worktreePath", .text)
                t.column("worktreeBaseCheckoutPath", .text)
                t.column("status", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("lastActiveAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v2_addTerminalScrollback") { db in
            try db.alter(table: "session") { table in
                table.add(column: "terminalScrollback", .blob).notNull().defaults(to: Data())
            }
        }
        return migrator
    }

    public func loadAll() throws -> (projects: [Project], sessions: [Session]) {
        try dbQueue.read { db in
            let projects = try ProjectRecord.fetchAll(db).map { try $0.toDomain() }
            let sessions = try SessionRecord.fetchAll(db).map { try $0.toDomain() }
            return (projects, sessions)
        }
    }

    public func save(_ project: Project) throws {
        try dbQueue.write { db in
            try ProjectRecord(project: project).save(db)
        }
    }

    public func save(_ session: Session) throws {
        try dbQueue.write { db in
            try SessionRecord(session: session).save(db)
        }
    }

    public func delete(sessionID: UUID) throws {
        _ = try dbQueue.write { db in
            try SessionRecord.deleteOne(db, key: sessionID.uuidString)
        }
    }
}
