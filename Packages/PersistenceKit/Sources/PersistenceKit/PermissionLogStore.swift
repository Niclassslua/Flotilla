import Foundation
import GRDB

/// One recorded permission ask, already normalized to a pattern by the app
/// layer (`PermissionPattern.normalize`) — this store only counts and
/// prunes, it never parses hook payloads itself.
public struct PermissionLogEntry: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "permission_request"

    public var id: Int64?
    public var sessionID: String
    public var agent: String
    public var tool: String
    public var pattern: String
    public var createdAt: Date

    public init(sessionID: String, agent: String, tool: String, pattern: String, createdAt: Date = .now) {
        self.sessionID = sessionID
        self.agent = agent
        self.tool = tool
        self.pattern = pattern
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A count for one pattern, aggregated over a window — what Home's Top
/// permissions widget renders directly.
public struct PermissionPatternCount: Sendable, Equatable {
    public var pattern: String
    public var tool: String
    public var count: Int
}

/// Small standalone GRDB store for permission asks, kept separate from
/// `GRDBSessionRepository` since it's an append-mostly log with its own
/// retention policy (30 days) rather than session-lifecycle-bound state.
public final class PermissionLogStore: @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    public static let retention: TimeInterval = 30 * 24 * 60 * 60

    public init(path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(path: path.path)
        try migrate()
    }

    /// In-memory, for UI tests and previews.
    public init() throws {
        dbQueue = try DatabaseQueue()
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_createPermissionRequest") { db in
            try db.create(table: "permission_request") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sessionID", .text).notNull()
                t.column("agent", .text).notNull()
                t.column("tool", .text).notNull()
                t.column("pattern", .text).notNull().indexed()
                t.column("createdAt", .datetime).notNull().indexed()
            }
        }
        try migrator.migrate(dbQueue)
    }

    public func record(sessionID: String, agent: String, tool: String, pattern: String, at date: Date = .now) throws {
        try dbQueue.write { db in
            var entry = PermissionLogEntry(sessionID: sessionID, agent: agent, tool: tool, pattern: pattern, createdAt: date)
            try entry.insert(db)
        }
    }

    /// Patterns asked since `since`, busiest first, optionally narrowed to
    /// one agent and/or a set of session ids (a project's own sessions) —
    /// Home's Top permissions widget reads this directly.
    public func topPatterns(since: Date, agent: String? = nil, sessionIDs: [String]? = nil, limit: Int = 10) throws -> [PermissionPatternCount] {
        try dbQueue.read { db in
            var sql = """
                SELECT pattern, tool, COUNT(*) AS count
                FROM permission_request
                WHERE createdAt >= ?
                """
            var arguments: [DatabaseValueConvertible] = [since]
            if let agent {
                sql += " AND agent = ?"
                arguments.append(agent)
            }
            if let sessionIDs {
                guard !sessionIDs.isEmpty else { return [] }
                let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ",")
                sql += " AND sessionID IN (\(placeholders))"
                arguments.append(contentsOf: sessionIDs)
            }
            sql += " GROUP BY pattern ORDER BY count DESC LIMIT ?"
            arguments.append(limit)
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            return rows.map { row in
                PermissionPatternCount(pattern: row["pattern"], tool: row["tool"], count: row["count"])
            }
        }
    }

    /// Deletes rows older than `retention`. Cheap enough to run once per
    /// launch rather than scheduling it separately.
    public func pruneExpired(now: Date = .now) throws {
        let cutoff = now.addingTimeInterval(-Self.retention)
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM permission_request WHERE createdAt < ?", arguments: [cutoff])
        }
    }
}
