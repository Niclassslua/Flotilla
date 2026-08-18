import Foundation

/// Persistence-agnostic seam — SessionKit knows nothing about SQLite/GRDB.
/// PersistenceKit provides the real implementation.
public protocol SessionRepository: Sendable {
    func loadAll() throws -> (projects: [Project], sessions: [Session])
    func save(_ project: Project) throws
    func save(_ session: Session) throws
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
}
