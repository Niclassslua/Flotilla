import XCTest
import SessionKit
import PersistenceKit

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
        XCTAssertFalse(FileManager.default.fileExists(atPath: walPath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shmPath.path))
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
}
