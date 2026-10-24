import XCTest
import GRDB
import SessionKit
@testable import PersistenceKit

final class PersistenceKitTests: XCTestCase {
    /// GRDB stores `Date` with millisecond precision; `Date()` carries more
    /// than that, so fixtures use a fixed, millisecond-safe timestamp to
    /// allow exact round-trip equality checks rather than fuzzy comparisons.
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testRoundTripPersistsProjectsAndSessions() throws {
        let repo = try GRDBSessionRepository()

        let project = Project(name: "Flotilla", rootPath: URL(fileURLWithPath: "/Users/dev/Flotilla"))
        try repo.save(project)

        let session = Session(
            title: "Fix login bug",
            goal: "Users can't log in on Safari",
            agent: .claudeCode,
            model: "sonnet",
            effort: .high,
            projectID: project.id,
            workingDirectory: URL(fileURLWithPath: "/Users/dev/Flotilla"),
            worktree: WorktreeInfo(
                branchName: "flotilla/fix-login",
                worktreePath: URL(fileURLWithPath: "/Users/dev/.flotilla/worktrees/fix-login"),
                baseCheckoutPath: URL(fileURLWithPath: "/Users/dev/Flotilla")
            ),
            status: .waitingForInput,
            waitingReason: .planApproval,
            terminalScrollback: Data("restored terminal output\n".utf8),
            createdAt: Self.fixedDate,
            lastActiveAt: Self.fixedDate
        )
        try repo.save(session)

        let (loadedProjects, loadedSessions) = try repo.loadAll()
        XCTAssertEqual(loadedProjects, [project])
        XCTAssertEqual(loadedSessions, [session])
    }

    func testSaveTwiceUpdatesRatherThanDuplicates() throws {
        let repo = try GRDBSessionRepository()
        var session = Session(
            title: "Initial",
            goal: "Goal",
            agent: .codexCLI,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: nil
        )
        try repo.save(session)

        session.status = .working
        session.title = "Updated"
        try repo.save(session)

        let (_, sessions) = try repo.loadAll()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.title, "Updated")
        XCTAssertEqual(sessions.first?.status, .working)
    }

    func testDeleteRemovesSession() throws {
        let repo = try GRDBSessionRepository()
        let session = Session(
            title: "Throwaway",
            goal: "Goal",
            agent: .openCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: nil
        )
        try repo.save(session)
        try repo.delete(sessionID: session.id)

        let (_, sessions) = try repo.loadAll()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testCorruptedDatabaseFileRecoversWithFreshStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flotilla-corrupt-\(UUID().uuidString)")
        let dbPath = dir.appendingPathComponent("state.sqlite")
        let walPath = dir.appendingPathComponent("state.sqlite-wal")
        let shmPath = dir.appendingPathComponent("state.sqlite-shm")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("this is not a sqlite database".utf8).write(to: dbPath)
        try Data("corrupt wal".utf8).write(to: walPath)
        try Data("corrupt shm".utf8).write(to: shmPath)

        let repo = try GRDBSessionRepository(path: dbPath)

        XCTAssertTrue(repo.recoveredFromCorruption)
        let backupName = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: dir.path)
            .first { $0.hasPrefix("state.sqlite.corrupt-") && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") })
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(backupName)),
                       Data("this is not a sqlite database".utf8))
        let (projects, sessions) = try repo.loadAll()
        XCTAssertTrue(projects.isEmpty)
        XCTAssertTrue(sessions.isEmpty)

        // And the recovered store is fully usable afterwards.
        try repo.save(Project(name: "Recovered", rootPath: URL(fileURLWithPath: "/tmp")))
        let (projectsAfterSave, _) = try repo.loadAll()
        XCTAssertEqual(projectsAfterSave.count, 1)

        try? FileManager.default.removeItem(at: dir)
    }

    func testFreshDatabaseFileDoesNotReportRecovery() throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("flotilla-fresh-\(UUID().uuidString)")
            .appendingPathComponent("state.sqlite")

        let repo = try GRDBSessionRepository(path: dbPath)
        XCTAssertFalse(repo.recoveredFromCorruption)

        try? FileManager.default.removeItem(at: dbPath.deletingLastPathComponent())
    }

    func testPersistedStateSurvivesAcrossRepositoryInstances() throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("flotilla-restart-\(UUID().uuidString)")
            .appendingPathComponent("state.sqlite")

        let session = Session(
            title: "Survives restart",
            goal: "Goal",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: nil,
            createdAt: Self.fixedDate,
            lastActiveAt: Self.fixedDate
        )

        do {
            let repo = try GRDBSessionRepository(path: dbPath)
            try repo.save(session)
        }

        // Simulates an app restart: brand new repository instance over the same file.
        let reopened = try GRDBSessionRepository(path: dbPath)
        let (_, sessions) = try reopened.loadAll()
        XCTAssertEqual(sessions, [session])

        try? FileManager.default.removeItem(at: dbPath.deletingLastPathComponent())
    }

    func testStatusSaveCommitsWhileAnotherConnectionReads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state.sqlite")
        let repo = try GRDBSessionRepository(path: path)
        var session = Session(title: "Active", goal: "Goal", agent: .codexCLI,
                              projectID: nil, workingDirectory: directory, status: .working)
        try repo.save(session)
        let reader = try DatabaseQueue(path: path.path)

        try reader.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT status FROM session"), "working")
            session = SessionStatusMachine().transition(session, to: .waitingForInput)
            try repo.save(session)
            // The reader retains its snapshot while the status commit succeeds.
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT status FROM session"), "working")
        }
        let reopened = try GRDBSessionRepository(path: path)
        XCTAssertEqual(try reopened.loadAll().sessions.first?.status, .waitingForInput)
        XCTAssertFalse(reopened.recoveredFromCorruption)
    }

    func testStatusSaveWaitsForAnotherWriter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state.sqlite")
        let repo = try GRDBSessionRepository(path: path)
        var session = Session(title: "Active", goal: "Goal", agent: .codexCLI,
                              projectID: nil, workingDirectory: directory, status: .working)
        try repo.save(session)
        let writer = try DatabaseQueue(path: path.path)
        let locked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "Other writer committed")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                try writer.write { db in
                    try db.execute(sql: "UPDATE session SET title = 'Other writer'")
                    locked.signal()
                    guard release.wait(timeout: .now() + 5) == .success else {
                        XCTFail("Timed out releasing the other writer")
                        return
                    }
                }
            } catch {
                XCTFail("Other writer failed: \(error)")
            }
        }
        defer {
            release.signal()
            wait(for: [finished], timeout: 5)
        }
        XCTAssertEqual(locked.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { release.signal() }

        session = SessionStatusMachine().transition(session, to: .waitingForInput)
        try repo.save(session)
        XCTAssertEqual(try repo.loadAll().sessions.first?.status, .waitingForInput)
    }

    func testHandoffOwnershipColumnsRoundTrip() throws {
        let repo = try GRDBSessionRepository()
        let pending = PendingHandoff(
            sourceAgent: .claudeCode,
            sourceSessionID: "claude-session-uuid",
            sourceTranscriptPath: URL(fileURLWithPath: "/tmp/source/abc.jsonl"),
            startedAt: Self.fixedDate
        )
        let session = Session(
            title: "Handoff test",
            goal: "Goal",
            agent: .codexCLI,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: nil,
            agentSessionID: "codex-uuid",
            nativeTranscriptPath: URL(fileURLWithPath: "/tmp/target/rollout.jsonl"),
            pendingHandoff: pending,
            createdAt: Self.fixedDate,
            lastActiveAt: Self.fixedDate
        )
        try repo.save(session)

        let (_, sessions) = try repo.loadAll()
        let restored = try XCTUnwrap(sessions.first)
        XCTAssertEqual(restored.nativeTranscriptPath?.path, "/tmp/target/rollout.jsonl")
        XCTAssertEqual(restored.pendingHandoff, pending)
    }

    /// A session at rest carries no probation record, and must not invent one.
    func testSessionWithoutHandoffRoundTripsWithNilFields() throws {
        let repo = try GRDBSessionRepository()
        try repo.save(Session(
            title: "Ordinary",
            goal: "Goal",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: nil,
            createdAt: Self.fixedDate,
            lastActiveAt: Self.fixedDate
        ))

        let (_, sessions) = try repo.loadAll()
        let restored = try XCTUnwrap(sessions.first)
        XCTAssertNil(restored.nativeTranscriptPath)
        XCTAssertNil(restored.pendingHandoff)
    }

    func testAgentSessionIDPersistsAndRoundTrips() throws {
        let repo = try GRDBSessionRepository()
        let session = Session(
            title: "Resume test",
            goal: "Goal",
            agent: .antigravity,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: nil,
            agentSessionID: "agy-conv-12345",
            createdAt: Self.fixedDate,
            lastActiveAt: Self.fixedDate
        )
        try repo.save(session)

        let (_, sessions) = try repo.loadAll()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.agentSessionID, "agy-conv-12345")
    }

    /// Rows written before the status collapse carried `idle` / `finished` /
    /// `ready`; all three now decode to `readyForReview`.
    func testLegacyStatusStringsFoldIntoReadyForReview() {
        XCTAssertEqual(SessionStatus.parseLegacy(rawValue: "idle"), .readyForReview)
        XCTAssertEqual(SessionStatus.parseLegacy(rawValue: "finished"), .readyForReview)
        XCTAssertEqual(SessionStatus.parseLegacy(rawValue: "ready"), .readyForReview)
        XCTAssertEqual(SessionStatus.parseLegacy(rawValue: "working"), .working)
        XCTAssertEqual(SessionStatus.parseLegacy(rawValue: "crashed"), .crashed)
        XCTAssertNil(SessionStatus.parseLegacy(rawValue: "nonsense"))
    }

    /// A session with no observed status yet round-trips as `nil`, not as a
    /// decode failure.
    func testNilStatusRoundTrips() throws {
        let repo = try GRDBSessionRepository()
        let session = Session(
            title: "Fresh",
            goal: "Goal",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: nil,
            createdAt: Self.fixedDate,
            lastActiveAt: Self.fixedDate
        )
        try repo.save(session)

        let (_, sessions) = try repo.loadAll()
        XCTAssertEqual(sessions, [session])
        XCTAssertNil(sessions.first?.status)
    }

    func testUpdateScrollbackDoesNotResurrectDeletedSession() throws {
        let repo = try GRDBSessionRepository()
        let session = Session(
            title: "Will Delete",
            goal: "Goal",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: nil,
            createdAt: Self.fixedDate,
            lastActiveAt: Self.fixedDate
        )
        try repo.save(session)
        try repo.delete(sessionID: session.id)

        // Delayed scrollback write arrives after deletion
        try repo.updateScrollback(sessionID: session.id, scrollback: Data("late terminal output\n".utf8))

        let (_, sessions) = try repo.loadAll()
        XCTAssertTrue(sessions.isEmpty, "updateScrollback must not resurrect a deleted session")
        XCTAssertNil(repo.loadScrollback(sessionID: session.id))
    }

    func testUpdateScrollbackOnlyModifiesScrollbackField() throws {
        let repo = try GRDBSessionRepository()
        var session = Session(
            title: "Original Title",
            goal: "Original Goal",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working,
            terminalScrollback: Data("initial\n".utf8),
            createdAt: Self.fixedDate,
            lastActiveAt: Self.fixedDate
        )
        try repo.save(session)

        let newScrollback = Data("updated terminal scrollback\n".utf8)
        try repo.updateScrollback(sessionID: session.id, scrollback: newScrollback)

        let (_, sessions) = try repo.loadAll()
        let loaded = try XCTUnwrap(sessions.first)
        XCTAssertEqual(loaded.terminalScrollback, newScrollback)
        XCTAssertEqual(loaded.title, "Original Title")
        XCTAssertEqual(loaded.status, .working)
        XCTAssertEqual(loaded.goal, "Original Goal")
    }

    func testCorruptionClassification() {
        // Non-corruption errors must not be classified as corruption
        let permError = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: [NSLocalizedDescriptionKey: "Permission denied"])
        XCTAssertFalse(GRDBSessionRepository.isCorruptionError(permError))

        let notFoundError = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: [NSLocalizedDescriptionKey: "No such file"])
        XCTAssertFalse(GRDBSessionRepository.isCorruptionError(notFoundError))

        // Result-code / exact open-time messages — not loose "malformed" matches
        let corruptError = NSError(domain: "SQLite", code: 11, userInfo: [NSLocalizedDescriptionKey: "database disk image is malformed"])
        XCTAssertTrue(GRDBSessionRepository.isCorruptionError(corruptError))

        let notADbError = NSError(domain: "SQLite", code: 26, userInfo: [NSLocalizedDescriptionKey: "file is not a database"])
        XCTAssertTrue(GRDBSessionRepository.isCorruptionError(notADbError))

        let migrateSQL = NSError(
            domain: "SQLite",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "SQL logic error near malformed column definition"]
        )
        XCTAssertFalse(
            GRDBSessionRepository.isCorruptionError(migrateSQL),
            "migrate/SQL diagnostics containing 'malformed' must not wipe the DB"
        )
    }

    func testLoadAllSkipsUndecodableSessionRows() throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("flotilla-skip-\(UUID().uuidString)")
            .appendingPathComponent("state.sqlite")
        defer { try? FileManager.default.removeItem(at: dbPath.deletingLastPathComponent()) }

        let good = Session(
            title: "Good",
            goal: "Goal",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working,
            createdAt: Self.fixedDate,
            lastActiveAt: Self.fixedDate
        )
        do {
            let disk = try GRDBSessionRepository(path: dbPath)
            try disk.save(good)
        }

        let queue = try DatabaseQueue(path: dbPath.path)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO session (
                        id, title, goal, agent, workingDirectory, status,
                        terminalScrollback, createdAt, lastActiveAt
                    ) VALUES (?, 'Bad', 'x', 'unknownAgent', '/tmp', 'working', ?, ?, ?)
                    """,
                arguments: [UUID().uuidString, Data(), Self.fixedDate, Self.fixedDate]
            )
        }

        let reopened = try GRDBSessionRepository(path: dbPath)
        let (_, sessions) = try reopened.loadAll()
        XCTAssertEqual(sessions.map(\.title), ["Good"])
    }

    func testUpdateScrollbackDoesNotShrinkNewerBuffer() throws {
        let repo = try GRDBSessionRepository()
        let session = Session(
            title: "Race",
            goal: "Goal",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working,
            terminalScrollback: Data("short\n".utf8),
            createdAt: Self.fixedDate,
            lastActiveAt: Self.fixedDate
        )
        try repo.save(session)

        var newer = session
        newer.terminalScrollback = Data("much longer scrollback that won the race\n".utf8)
        try repo.save(newer)

        try repo.updateScrollback(sessionID: session.id, scrollback: Data("short\n".utf8))
        let loaded = try XCTUnwrap(try repo.loadAll().sessions.first)
        XCTAssertEqual(
            String(decoding: loaded.terminalScrollback, as: UTF8.self),
            "much longer scrollback that won the race\n"
        )
    }

    func testKanbanLegacyStatusFilterInJSONSurvivesLoad() throws {
        let json = """
        [{"id":"AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE","title":"Ready","order":0,"statusFilter":"ready"}]
        """
        let columns = KanbanBoardRecord.decodeCustomColumns(json)
        XCTAssertEqual(columns.count, 1)
        XCTAssertEqual(columns.first?.statusFilter, .readyForReview)
        XCTAssertEqual(columns.first?.title, "Ready")
    }

    func testKanbanSkipsBadColumnWithoutWipingSiblings() {
        let json = """
        [
          {"id":"AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE","title":"Working","order":0,"statusFilter":"working"},
          {"title":"missing-id","order":1},
          {"id":"BBBBBBBB-BBBB-4CCC-8DDD-EEEEEEEEEEEE","title":"Review","order":2,"statusFilter":"idle"}
        ]
        """
        let columns = KanbanBoardRecord.decodeCustomColumns(json)
        XCTAssertEqual(columns.map(\.title), ["Working", "Review"])
        XCTAssertEqual(columns[1].statusFilter, .readyForReview)
    }

    func testMutationBlockedRepositoryRefusesWrites() throws {
        let inner = try GRDBSessionRepository()
        let blocked = MutationBlockedSessionRepository(wrapping: inner, detail: "disk full")
        XCTAssertFalse(blocked.acceptsMutations)
        XCTAssertTrue(try blocked.loadAll().sessions.isEmpty)
        XCTAssertThrowsError(try blocked.save(Session(
            title: "Nope",
            goal: "g",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )))
    }

    func testCorruptionRecoveryPreservesDamagedFileAndRecreates() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("flotilla.sqlite")
        try "Garbage non-sqlite content".write(to: dbPath, atomically: true, encoding: .utf8)

        let repo = try GRDBSessionRepository(path: dbPath)
        XCTAssertTrue(repo.recoveredFromCorruption)

        // Check that a corrupt backup file was created
        let items = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let backupFiles = items.filter { $0.contains("corrupt-") }
        XCTAssertFalse(backupFiles.isEmpty, "A corrupt backup file should have been created")

        // The new repository should be operational
        let (projects, sessions) = try repo.loadAll()
        XCTAssertTrue(projects.isEmpty)
        XCTAssertTrue(sessions.isEmpty)
    }
}
