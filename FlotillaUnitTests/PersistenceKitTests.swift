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
            status: .working,
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
            status: .idle
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
            status: .idle
        )
        try repo.save(session)
        try repo.delete(sessionID: session.id)

        let (_, sessions) = try repo.loadAll()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testGeneralSessionHasNilProjectID() throws {
        let repo = try GRDBSessionRepository()
        let session = Session(
            title: "General",
            goal: "No project tie",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .idle
        )
        try repo.save(session)

        let (_, sessions) = try repo.loadAll()
        XCTAssertNil(sessions.first?.projectID)
    }

    func testCorruptedDatabaseFileRecoversWithFreshStore() throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("flotilla-corrupt-\(UUID().uuidString)")
            .appendingPathComponent("state.sqlite")
        try FileManager.default.createDirectory(at: dbPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("this is not a sqlite database".utf8).write(to: dbPath)

        let repo = try GRDBSessionRepository(path: dbPath)

        XCTAssertTrue(repo.recoveredFromCorruption)
        let (projects, sessions) = try repo.loadAll()
        XCTAssertTrue(projects.isEmpty)
        XCTAssertTrue(sessions.isEmpty)

        // And the recovered store is fully usable afterwards.
        try repo.save(Project(name: "Recovered", rootPath: URL(fileURLWithPath: "/tmp")))
        let (projectsAfterSave, _) = try repo.loadAll()
        XCTAssertEqual(projectsAfterSave.count, 1)

        try? FileManager.default.removeItem(at: dbPath.deletingLastPathComponent())
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
            status: .idle,
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
}
