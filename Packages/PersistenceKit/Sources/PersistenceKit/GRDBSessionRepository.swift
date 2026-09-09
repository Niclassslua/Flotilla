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
            let fileManager = FileManager.default
            for ext in ["", "-wal", "-shm"] {
                let fileURL = URL(fileURLWithPath: path.path + ext)
                let corruptURL = URL(fileURLWithPath: corruptPath.path + ext)
                if fileManager.fileExists(atPath: fileURL.path) {
                    try? fileManager.moveItem(at: fileURL, to: corruptURL)
                }
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

    /// Internal rather than private so tests can migrate a database only part
    /// of the way and prove the *upgrade* path, not just a fresh install. A
    /// fresh database cannot catch a migration that was edited after it ran.
    static var migrator: DatabaseMigrator {
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
        migrator.registerMigration("v3_addModelAndEffort") { db in
            try db.alter(table: "session") { table in
                table.add(column: "model", .text)
                table.add(column: "effort", .text)
            }
        }
        migrator.registerMigration("v4_addKanbanAndSessionKanbanFields") { db in
            // Add kanban columns to session table
            try db.alter(table: "session") { table in
                table.add(column: "kanbanColumnID", .text)
                table.add(column: "workflowStage", .text)
            }
            // Create kanban_board table
            try db.create(table: "kanban_board") { t in
                t.column("id", .text).primaryKey()
                t.column("projectID", .text)
                t.column("name", .text).notNull()
                t.column("columnMode", .text).notNull()
                t.column("customColumnsJSON", .text).notNull()
                t.column("cardOrderJSON", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            // Create kanban_column table
            try db.create(table: "kanban_column") { t in
                t.column("id", .text).primaryKey()
                t.column("boardID", .text).notNull()
                t.column("title", .text).notNull()
                t.column("order", .integer).notNull()
                t.column("statusFilter", .text)
                t.column("agentFilter", .text)
                t.column("workflowStageFilter", .text)
                t.column("color", .text)
            }
            try db.create(index: "idx_kanban_column_boardID", on: "kanban_column", columns: ["boardID"])
        }
        migrator.registerMigration("v5_addAgentSessionID") { db in
            try db.alter(table: "session") { table in
                table.add(column: "agentSessionID", .text)
            }
        }
        migrator.registerMigration("v6_addSessionWaitingReason") { db in
            try db.alter(table: "session") { table in
                table.add(column: "waitingReason", .text)
            }
        }
        migrator.registerMigration("v7_collapseStatuses") { db in
            // `idle` and `finished` are gone; both read as `readyForReview`
            // now, and `ready` is renamed to it. A brand-new session with no
            // observed work is stored as an empty status string (decoded as
            // nil) — every existing row already carries a real value, so
            // none is rewritten to empty here.
            try db.execute(sql: """
                UPDATE session SET status = 'readyForReview'
                WHERE status IN ('idle', 'finished', 'ready')
                """)
            // Custom-board columns never match on statusFilter, but keep the
            // stored value coherent for anything that inspects it later.
            try db.execute(sql: """
                UPDATE kanban_column SET statusFilter = 'readyForReview'
                WHERE statusFilter = 'ready'
                """)
            try db.execute(sql: """
                UPDATE kanban_column SET statusFilter = NULL
                WHERE statusFilter IN ('idle', 'finished')
                """)
        }
        migrator.registerMigration("v8_addHandoffOwnership") { db in
            // Which transcript the session's agent currently owns, and — while
            // a handoff is on probation — what to put back if the destination
            // never starts. All nullable: every existing session predates
            // handoff and has neither.
            try db.alter(table: "session") { table in
                table.add(column: "nativeTranscriptPath", .text)
                table.add(column: "handoffSourceAgent", .text)
                table.add(column: "handoffSourceTranscriptPath", .text)
                table.add(column: "handoffStartedAt", .datetime)
            }
        }
        migrator.registerMigration("v9_addHandoffSourceSessionID") { db in
            // Separate from v8 on purpose. This column belongs with the four
            // above and was meant to ship inside v8, but v8 had already run on
            // real databases by the time it was needed — and a migrator skips a
            // migration it has already recorded, so editing v8 added the column
            // for nobody while every new install looked correct. A migration
            // that has run anywhere is immutable; the only way to add to it is
            // to add after it.
            try db.alter(table: "session") { table in
                table.add(column: "handoffSourceSessionID", .text)
            }
        }
        migrator.registerMigration("v10_addHandoffSourceModelAndEffort") { db in
            // A handoff clears the session's model and effort, because both
            // name a specific vendor's options. These remember what to put back
            // if the move is rolled back.
            try db.alter(table: "session") { table in
                table.add(column: "handoffSourceModel", .text)
                table.add(column: "handoffSourceEffort", .text)
            }
        }
        migrator.registerMigration("v11_addReviewCommentsAndViewedFiles") { db in
            try db.create(table: "review_comment") { t in
                t.column("id", .text).primaryKey()
                t.column("sessionID", .text)
                    .notNull()
                    .indexed()
                    .references("session", onDelete: .cascade)
                t.column("filePath", .text).notNull()
                // "file" for a whole-file comment, otherwise "old"/"new".
                t.column("anchorSide", .text)
                t.column("anchorLine", .integer)
                t.column("body", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("sentAt", .datetime)
            }
            try db.create(table: "review_viewed_file") { t in
                t.column("sessionID", .text)
                    .notNull()
                    .references("session", onDelete: .cascade)
                t.column("scope", .text).notNull()
                t.column("filePath", .text).notNull()
                t.column("diffFingerprint", .text).notNull()
                t.column("viewedAt", .datetime).notNull()
                // One mark per file per scope: re-viewing replaces the
                // fingerprint rather than accumulating rows.
                t.primaryKey(["sessionID", "scope", "filePath"])
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
    
    public func loadScrollback(sessionID: UUID) -> Data? {
        do {
            return try dbQueue.read { db in
                let record = try SessionRecord.fetchOne(db, key: sessionID.uuidString)
                return record?.terminalScrollback
            }
        } catch {
            return nil
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

    /// One transaction, one fsync, regardless of how many sessions are being
    /// flushed — see the protocol's declaration.
    public func save(_ sessions: [Session]) throws {
        guard !sessions.isEmpty else { return }
        try dbQueue.write { db in
            for session in sessions {
                try SessionRecord(session: session).save(db)
            }
        }
    }

    public func delete(sessionID: UUID) throws {
        _ = try dbQueue.write { db in
            try SessionRecord.deleteOne(db, key: sessionID.uuidString)
        }
    }

    public func delete(projectID: UUID) throws {
        _ = try dbQueue.write { db in
            try ProjectRecord.deleteOne(db, key: projectID.uuidString)
        }
    }

    // MARK: - Kanban Board Methods

    public func loadKanbanBoards() throws -> [KanbanBoard] {
        try dbQueue.read { db in
            let boardRecords = try KanbanBoardRecord.fetchAll(db)
            return try boardRecords.map { try $0.toDomain() }
        }
    }

    public func loadKanbanBoard(id: UUID) throws -> KanbanBoard? {
        try dbQueue.read { db in
            let record = try KanbanBoardRecord.fetchOne(db, key: id.uuidString)
            return try record?.toDomain()
        }
    }

    public func loadKanbanBoard(forProject projectID: UUID?) throws -> KanbanBoard? {
        try dbQueue.read { db in
            let projectIDString = projectID?.uuidString
            let record = try KanbanBoardRecord
                .filter(Column("projectID") == projectIDString)
                .fetchOne(db)
            return try record?.toDomain()
        }
    }

    public func saveKanbanBoard(_ board: KanbanBoard) throws {
        try dbQueue.write { db in
            var boardToSave = board
            boardToSave.updatedAt = Date()
            try KanbanBoardRecord(board: boardToSave).save(db)
            
            // Save custom columns
            if board.columnMode == .custom {
                // Delete existing columns for this board
                try KanbanColumnRecord
                    .filter(Column("boardID") == board.id.uuidString)
                    .deleteAll(db)
                
                // Insert new columns
                for column in board.customColumns {
                    try KanbanColumnRecord(column: column, boardID: board.id).save(db)
                }
            }
        }
    }

    public func deleteKanbanBoard(id: UUID) throws {
        try dbQueue.write { db in
            // Delete columns first (foreign key not enforced, manual cleanup)
            try KanbanColumnRecord
                .filter(Column("boardID") == id.uuidString)
                .deleteAll(db)
            _ = try KanbanBoardRecord.deleteOne(db, key: id.uuidString)
        }
    }

    public func getOrCreateDefaultKanbanBoard(forProject projectID: UUID?, name: String) throws -> KanbanBoard {
        if let existing = try loadKanbanBoard(forProject: projectID) {
            return existing
        }
        
        let defaultColumns: [KanbanColumn]
        let columnMode: KanbanColumnMode
        
        if projectID == nil {
            // Global board - only status mode makes sense
            columnMode = .status
            defaultColumns = KanbanColumn.defaultStatusColumns()
        } else {
            columnMode = .status
            defaultColumns = KanbanColumn.defaultStatusColumns()
        }
        
        let board = KanbanBoard(
            projectID: projectID,
            name: name,
            columnMode: columnMode,
            customColumns: defaultColumns
        )
        try saveKanbanBoard(board)
        return board
    }

    // MARK: - Review

    public func loadReviewComments(sessionID: UUID) throws -> [ReviewComment] {
        try dbQueue.read { db in
            try ReviewCommentRecord
                .filter(Column("sessionID") == sessionID.uuidString)
                .order(Column("createdAt"))
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    public func saveReviewComment(_ comment: ReviewComment) throws {
        _ = try dbQueue.write { db in
            try ReviewCommentRecord(comment: comment).save(db)
        }
    }

    public func deleteReviewComment(id: UUID) throws {
        _ = try dbQueue.write { db in
            try ReviewCommentRecord.deleteOne(db, key: id.uuidString)
        }
    }

    public func deleteReviewComments(sessionID: UUID) throws {
        _ = try dbQueue.write { db in
            try ReviewCommentRecord
                .filter(Column("sessionID") == sessionID.uuidString)
                .deleteAll(db)
        }
    }

    public func loadReviewedFiles(sessionID: UUID) throws -> [ReviewedFile] {
        try dbQueue.read { db in
            try ReviewedFileRecord
                .filter(Column("sessionID") == sessionID.uuidString)
                .fetchAll(db)
                .compactMap { $0.toDomain() }
        }
    }

    public func saveReviewedFile(_ file: ReviewedFile) throws {
        _ = try dbQueue.write { db in
            try ReviewedFileRecord(file: file).insert(db)
        }
    }

    public func deleteReviewedFile(sessionID: UUID, scope: ReviewScope, filePath: String) throws {
        _ = try dbQueue.write { db in
            try ReviewedFileRecord
                .filter(Column("sessionID") == sessionID.uuidString)
                .filter(Column("scope") == scope.rawValue)
                .filter(Column("filePath") == filePath)
                .deleteAll(db)
        }
    }
}
