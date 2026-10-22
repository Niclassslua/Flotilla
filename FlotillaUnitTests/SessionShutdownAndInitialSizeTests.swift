import XCTest
import SessionKit
import ProcessKit
import GitKit
import PersistenceKit
import SettingsKit
import TerminalKit
import HooksKit
@testable import Flotilla

@MainActor
final class SessionShutdownAndInitialSizeTests: XCTestCase {
    func testFlushLiveScrollbackPersistsAllBuffersSynchronously() async throws {
        let repo = try GRDBSessionRepository()
        let session = Session(
            title: "Flush Test",
            goal: "Goal",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working,
            terminalScrollback: Data()
        )
        try repo.save(session)

        let store = AppStore(
            repository: repo,
            gitService: MockGitService(),
            processManager: SessionProcessManager(
                locator: AppLayerExecutableLocator(executable: URL(fileURLWithPath: "/bin/echo")),
                processFactory: RecordingProcessFactory()
            ),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp") }
        )

        store.appendTerminalOutput(Data("output-to-flush\n".utf8), toSessionID: session.id)

        // Calling flushLiveScrollback immediately forces persistence without waiting for debounce
        store.flushLiveScrollback()

        let (_, loadedSessions) = try repo.loadAll()
        let loaded = try XCTUnwrap(loadedSessions.first(where: { $0.id == session.id }))
        XCTAssertEqual(String(decoding: loaded.terminalScrollback, as: UTF8.self), "output-to-flush\n")
    }

    func testFlushLiveScrollbackSurfacesRepositoryErrors() async throws {
        let inner = try GRDBSessionRepository()
        let session = Session(
            title: "Flush Fail",
            goal: "Goal",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working
        )
        try inner.save(session)

        let failing = ScrollbackUpdateFailingRepository(inner: inner)
        let store = AppStore(
            repository: failing,
            gitService: MockGitService(),
            processManager: SessionProcessManager(
                locator: AppLayerExecutableLocator(executable: URL(fileURLWithPath: "/bin/echo")),
                processFactory: RecordingProcessFactory()
            ),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp") }
        )
        store.appendTerminalOutput(Data("tail\n".utf8), toSessionID: session.id)
        store.flushLiveScrollback()
        XCTAssertEqual(
            store.lastOperationError,
            "Terminal history could not be saved on quit: scrollback flush failed"
        )
    }
}

/// Forwards everything except `updateScrollback`, which always throws.
private struct ScrollbackUpdateFailingRepository: SessionRepository {
    let inner: SessionRepository

    func loadAll() throws -> (projects: [Project], sessions: [Session]) { try inner.loadAll() }
    func save(_ project: Project) throws { try inner.save(project) }
    func save(_ session: Session) throws { try inner.save(session) }
    func delete(sessionID: UUID) throws { try inner.delete(sessionID: sessionID) }
    func delete(projectID: UUID) throws { try inner.delete(projectID: projectID) }
    func loadScrollback(sessionID: UUID) -> Data? { inner.loadScrollback(sessionID: sessionID) }
    func updateScrollback(sessionID: UUID, scrollback: Data) throws {
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "scrollback flush failed"])
    }
    func loadKanbanBoards() throws -> [KanbanBoard] { try inner.loadKanbanBoards() }
    func loadKanbanBoard(id: UUID) throws -> KanbanBoard? { try inner.loadKanbanBoard(id: id) }
    func loadKanbanBoard(forProject projectID: UUID?) throws -> KanbanBoard? {
        try inner.loadKanbanBoard(forProject: projectID)
    }
    func saveKanbanBoard(_ board: KanbanBoard) throws { try inner.saveKanbanBoard(board) }
    func deleteKanbanBoard(id: UUID) throws { try inner.deleteKanbanBoard(id: id) }
    func getOrCreateDefaultKanbanBoard(forProject projectID: UUID?, name: String) throws -> KanbanBoard {
        try inner.getOrCreateDefaultKanbanBoard(forProject: projectID, name: name)
    }
    func loadReviewComments(sessionID: UUID) throws -> [ReviewComment] {
        try inner.loadReviewComments(sessionID: sessionID)
    }
    func saveReviewComment(_ comment: ReviewComment) throws { try inner.saveReviewComment(comment) }
    func markReviewCommentsSent(sessionID: UUID, commentIDs: Set<UUID>, at date: Date) throws {
        try inner.markReviewCommentsSent(sessionID: sessionID, commentIDs: commentIDs, at: date)
    }
    func deleteReviewComment(id: UUID) throws { try inner.deleteReviewComment(id: id) }
    func deleteReviewComments(sessionID: UUID) throws { try inner.deleteReviewComments(sessionID: sessionID) }
    func loadReviewedFiles(sessionID: UUID) throws -> [ReviewedFile] {
        try inner.loadReviewedFiles(sessionID: sessionID)
    }
    func saveReviewedFile(_ file: ReviewedFile) throws { try inner.saveReviewedFile(file) }
    func deleteReviewedFile(sessionID: UUID, scope: ReviewScope, filePath: String) throws {
        try inner.deleteReviewedFile(sessionID: sessionID, scope: scope, filePath: filePath)
    }
    func saveAttributionSession(_ snapshot: AttributionSessionSnapshot) throws {
        try inner.saveAttributionSession(snapshot)
    }
    func loadAttributionSessions(repositoryKey: String) throws -> [AttributionSessionSnapshot] {
        try inner.loadAttributionSessions(repositoryKey: repositoryKey)
    }
    func saveAttributedCommits(_ commits: [AttributedCommit], links: [AttributedCommitLink]) throws {
        try inner.saveAttributedCommits(commits, links: links)
    }
    func loadAttributedCommits(repositoryKey: String) throws -> [AttributedCommit] {
        try inner.loadAttributedCommits(repositoryKey: repositoryKey)
    }
    func loadAttributedCommitLinks(repositoryKey: String) throws -> [AttributedCommitLink] {
        try inner.loadAttributedCommitLinks(repositoryKey: repositoryKey)
    }
    func saveAttributedCommitLinks(_ links: [AttributedCommitLink]) throws {
        try inner.saveAttributedCommitLinks(links)
    }
    func deleteAllCommitAttribution() throws { try inner.deleteAllCommitAttribution() }
}
