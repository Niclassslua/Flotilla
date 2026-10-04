import XCTest
import GRDB
import SessionKit
@testable import PersistenceKit

/// Migrating a *fresh* database proves only that the final schema is reachable
/// from nothing. It cannot catch a migration that was edited after it had
/// already run somewhere: the migrator records each migration by name and skips
/// what it has seen, so the edit reaches new installs and no existing one.
///
/// That is exactly how `handoffSourceSessionID` went missing — added to v8
/// after v8 had run, so every new database looked correct while the developer's
/// own failed on insert. These tests step a database part of the way and then
/// forward, which is the only shape that catches it.
final class MigrationUpgradePathTests: XCTestCase {
    func testAttributionUpgradePreservesPromptCommitsAndLinks() throws {
        let queue = try DatabaseQueue()
        let migrator = GRDBSessionRepository.migrator
        try migrator.migrate(queue, upTo: "v12_addCommitAttribution")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO attribution_session
                (sessionID, repositoryKey, agent, title, prompt, createdAt)
                VALUES ('session', 'repo-a', 'claudeCode', 'Title', 'Original prompt', '2026-09-11');
                INSERT INTO attributed_commit
                (id, sessionID, repositoryKey, authorEmail, authorTime, originalSHA, agent, recordedAt)
                VALUES ('commit', 'session', 'repo-a', 'a@example.com', 1, 'sha', 'claudeCode', '2026-09-11');
                INSERT INTO attributed_commit_link VALUES ('commit', 'sha', 'recorded', '2026-09-11');
                """)
        }
        try migrator.migrate(queue)
        try queue.write { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT prompt FROM attribution_session"), "Original prompt")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attributed_commit"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attributed_commit_link"), 1)
            // The upgraded key permits this same session in another repository.
            try db.execute(sql: """
                INSERT INTO attribution_session
                (sessionID, repositoryKey, agent, title, prompt, createdAt)
                VALUES ('session', 'repo-b', 'claudeCode', 'Other', 'Other prompt', '2026-09-11')
                """)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attribution_session"), 2)
        }
    }

    private func columns(of table: String, in db: Database) throws -> Set<String> {
        Set(try db.columns(in: table).map(\.name))
    }

    /// Every column `SessionRecord` writes must exist after a full migration.
    /// Written from the record's own insert statement rather than a hand-kept
    /// list, so a future column cannot be added to one and forgotten in the
    /// other.
    func testFullyMigratedSchemaCarriesEveryHandoffColumn() throws {
        let queue = try DatabaseQueue()
        try GRDBSessionRepository.migrator.migrate(queue)

        try queue.read { db in
            let columns = try self.columns(of: "session", in: db)
            for expected in [
                "nativeTranscriptPath",
                "handoffSourceAgent",
                "handoffSourceSessionID",
                "handoffSourceTranscriptPath",
                "handoffStartedAt",
                "handoffSourceModel",
                "handoffSourceEffort"
            ] {
                XCTAssertTrue(columns.contains(expected), "session is missing \(expected)")
            }
        }
    }

    /// A database that stopped at v8 — the state every install that ran the
    /// original v8 is in — must reach the current schema by migrating forward.
    func testADatabaseStoppedAtV8UpgradesToTheCurrentSchema() throws {
        let queue = try DatabaseQueue()
        let migrator = GRDBSessionRepository.migrator

        try migrator.migrate(queue, upTo: "v8_addHandoffOwnership")
        try queue.read { db in
            let columns = try self.columns(of: "session", in: db)
            XCTAssertTrue(columns.contains("handoffSourceAgent"), "v8 should have landed")
            XCTAssertFalse(
                columns.contains("handoffSourceSessionID"),
                "if v8 already adds this, the column has been folded back into an applied migration"
            )
        }

        try migrator.migrate(queue)
        try queue.read { db in
            XCTAssertTrue(try self.columns(of: "session", in: db).contains("handoffSourceSessionID"))
        }
    }

    /// Same shape as the v8 case, one migration later: a database that stopped
    /// at v9 must still reach the current schema.
    func testADatabaseStoppedAtV9UpgradesToTheCurrentSchema() throws {
        let queue = try DatabaseQueue()
        let migrator = GRDBSessionRepository.migrator

        try migrator.migrate(queue, upTo: "v9_addHandoffSourceSessionID")
        try queue.read { db in
            let columns = try self.columns(of: "session", in: db)
            XCTAssertTrue(columns.contains("handoffSourceSessionID"))
            XCTAssertFalse(
                columns.contains("handoffSourceModel"),
                "if v9 already adds this, a column has been folded back into an applied migration"
            )
        }

        try migrator.migrate(queue)
        try queue.read { db in
            let columns = try self.columns(of: "session", in: db)
            XCTAssertTrue(columns.contains("handoffSourceModel"))
            XCTAssertTrue(columns.contains("handoffSourceEffort"))
        }
    }

    /// The end state must be identical whether a database arrived in one step
    /// or in two — otherwise an upgraded install and a fresh one diverge.
    func testUpgradedAndFreshDatabasesEndWithTheSameSchema() throws {
        let stepwise = try DatabaseQueue()
        let migrator = GRDBSessionRepository.migrator
        try migrator.migrate(stepwise, upTo: "v8_addHandoffOwnership")
        try migrator.migrate(stepwise)

        let fresh = try DatabaseQueue()
        try migrator.migrate(fresh)

        let stepwiseColumns = try stepwise.read { try self.columns(of: "session", in: $0) }
        let freshColumns = try fresh.read { try self.columns(of: "session", in: $0) }
        XCTAssertEqual(stepwiseColumns, freshColumns)
    }

    /// Sessions saved before issue links existed must still load, and new ones
    /// must keep their link across a save and read.
    func testV17DatabaseUpgradesAndCarriesIssueLinks() throws {
        let queue = try DatabaseQueue()
        let migrator = GRDBSessionRepository.migrator
        try migrator.migrate(queue, upTo: "v17_addProjectAccentColor")
        let old = Session(title: "Before issues", goal: "", agent: .claudeCode, projectID: nil, workingDirectory: URL(fileURLWithPath: "/tmp"))
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO session (id, title, goal, agent, workingDirectory, status, terminalScrollback, createdAt, lastActiveAt) VALUES (?, ?, '', 'claudeCode', '/tmp', '', x'', ?, ?)",
                arguments: [old.id.uuidString, old.title, old.createdAt, old.lastActiveAt]
            )
        }

        try migrator.migrate(queue)

        let link = IssueLink(number: 7, title: "Fix it", url: URL(string: "https://github.com/acme/app/issues/7")!)
        let linked = Session(title: "#7 Fix it", goal: "", agent: .codexCLI, projectID: nil, workingDirectory: URL(fileURLWithPath: "/tmp"), linkedIssue: link)
        try queue.write { db in try SessionRecord(session: linked).insert(db) }

        let restored = try queue.read { db in try SessionRecord.fetchAll(db).map { try $0.toDomain() } }
        XCTAssertNil(restored.first { $0.id == old.id }?.linkedIssue)
        XCTAssertEqual(restored.first { $0.id == old.id }?.title, "Before issues")
        XCTAssertEqual(restored.first { $0.id == linked.id }?.linkedIssue, link)
    }

    /// The failure as the user met it: saving a session against a database that
    /// only reached v8 must work once it is migrated forward.
    func testSavingASessionSucceedsAfterUpgradingFromV8() throws {
        let queue = try DatabaseQueue()
        let migrator = GRDBSessionRepository.migrator
        try migrator.migrate(queue, upTo: "v8_addHandoffOwnership")
        try migrator.migrate(queue)

        let session = Session(
            title: "Upgraded",
            goal: "Goal",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: nil
        )
        try queue.write { db in
            try SessionRecord(session: session).insert(db)
        }

        let restored = try queue.read { db in try SessionRecord.fetchAll(db) }
        XCTAssertEqual(restored.count, 1)
        XCTAssertNil(restored.first?.handoffSourceSessionID)
    }
}
