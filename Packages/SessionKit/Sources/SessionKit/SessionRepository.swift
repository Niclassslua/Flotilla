import Foundation

/// Persistence-agnostic seam — SessionKit knows nothing about SQLite/GRDB.
/// PersistenceKit provides the real implementation.
public protocol SessionRepository: Sendable {
    func loadAll() throws -> (projects: [Project], sessions: [Session])
    func save(_ project: Project) throws
    func save(_ session: Session) throws

    /// Persists several sessions in one transaction.
    ///
    /// Quitting flushes every session's live scrollback at once; one fsyncing
    /// write per session made that scale with the size of the fleet, on the
    /// main thread, while the user waited for the window to close.
    func save(_ sessions: [Session]) throws
    func delete(sessionID: UUID) throws
    func delete(projectID: UUID) throws
    func loadScrollback(sessionID: UUID) -> Data?
    
    // MARK: - Kanban
    func loadKanbanBoards() throws -> [KanbanBoard]
    func loadKanbanBoard(id: UUID) throws -> KanbanBoard?
    func loadKanbanBoard(forProject projectID: UUID?) throws -> KanbanBoard?
    func saveKanbanBoard(_ board: KanbanBoard) throws
    func deleteKanbanBoard(id: UUID) throws
    func getOrCreateDefaultKanbanBoard(forProject projectID: UUID?, name: String) throws -> KanbanBoard

    // MARK: - Review

    /// Every comment left on a session's work, in creation order.
    func loadReviewComments(sessionID: UUID) throws -> [ReviewComment]
    func saveReviewComment(_ comment: ReviewComment) throws
    func deleteReviewComment(id: UUID) throws
    /// Clears a session's whole review — used when the reviewer discards it.
    func deleteReviewComments(sessionID: UUID) throws
    func loadReviewedFiles(sessionID: UUID) throws -> [ReviewedFile]
    func saveReviewedFile(_ file: ReviewedFile) throws
    func deleteReviewedFile(sessionID: UUID, scope: ReviewScope, filePath: String) throws
}

public extension SessionRepository {
    /// Correct for any store; `GRDBSessionRepository` overrides it with a
    /// single transaction.
    func save(_ sessions: [Session]) throws {
        for session in sessions {
            try save(session)
        }
    }
}
