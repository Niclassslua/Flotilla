import Foundation

/// Persistence-agnostic seam — SessionKit knows nothing about SQLite/GRDB.
/// PersistenceKit provides the real implementation.
public protocol SessionRepository: Sendable {
    func loadAll() throws -> (projects: [Project], sessions: [Session])
    func save(_ project: Project) throws
    func save(_ session: Session) throws
    func delete(sessionID: UUID) throws
}
