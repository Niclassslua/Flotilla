import Foundation
import SessionKit

/// Forwards reads to an inner store but refuses every mutation.
///
/// Used when the on-disk database cannot be opened: an empty scratch DB keeps
/// the UI alive, but creating/saving must not silently succeed into memory
/// that vanishes on quit.
public struct MutationBlockedSessionRepository: SessionRepository {
    public enum Error: LocalizedError {
        case unavailable(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable(let detail):
                "Persistent session storage is unavailable (\(detail))"
            }
        }
    }

    private let inner: SessionRepository
    private let detail: String

    public init(wrapping inner: SessionRepository, detail: String) {
        self.inner = inner
        self.detail = detail
    }

    public var acceptsMutations: Bool { false }

    private func refuse() throws -> Never {
        throw Error.unavailable(detail)
    }

    public func loadAll() throws -> (projects: [Project], sessions: [Session]) {
        try inner.loadAll()
    }

    public func loadScrollback(sessionID: UUID) -> Data? {
        inner.loadScrollback(sessionID: sessionID)
    }

    public func loadKanbanBoards() throws -> [KanbanBoard] {
        try inner.loadKanbanBoards()
    }

    public func loadKanbanBoard(id: UUID) throws -> KanbanBoard? {
        try inner.loadKanbanBoard(id: id)
    }

    public func loadKanbanBoard(forProject projectID: UUID?) throws -> KanbanBoard? {
        try inner.loadKanbanBoard(forProject: projectID)
    }

    public func loadReviewComments(sessionID: UUID) throws -> [ReviewComment] {
        try inner.loadReviewComments(sessionID: sessionID)
    }

    public func loadReviewedFiles(sessionID: UUID) throws -> [ReviewedFile] {
        try inner.loadReviewedFiles(sessionID: sessionID)
    }

    public func loadAttributionSessions(repositoryKey: String) throws -> [AttributionSessionSnapshot] {
        try inner.loadAttributionSessions(repositoryKey: repositoryKey)
    }

    public func loadAttributedCommits(repositoryKey: String) throws -> [AttributedCommit] {
        try inner.loadAttributedCommits(repositoryKey: repositoryKey)
    }

    public func loadAttributedCommitLinks(repositoryKey: String) throws -> [AttributedCommitLink] {
        try inner.loadAttributedCommitLinks(repositoryKey: repositoryKey)
    }

    public func save(_ project: Project) throws { try refuse() }
    public func save(_ session: Session) throws { try refuse() }
    public func save(_ sessions: [Session]) throws { try refuse() }
    public func delete(sessionID: UUID) throws { try refuse() }
    public func delete(projectID: UUID) throws { try refuse() }
    public func updateScrollback(sessionID: UUID, scrollback: Data) throws { try refuse() }
    public func saveKanbanBoard(_ board: KanbanBoard) throws { try refuse() }
    public func deleteKanbanBoard(id: UUID) throws { try refuse() }
    public func getOrCreateDefaultKanbanBoard(forProject projectID: UUID?, name: String) throws -> KanbanBoard {
        try refuse()
    }
    public func saveReviewComment(_ comment: ReviewComment) throws { try refuse() }
    public func markReviewCommentsSent(sessionID: UUID, commentIDs: Set<UUID>, at date: Date) throws { try refuse() }
    public func deleteReviewComment(id: UUID) throws { try refuse() }
    public func deleteReviewComments(sessionID: UUID) throws { try refuse() }
    public func saveReviewedFile(_ file: ReviewedFile) throws { try refuse() }
    public func deleteReviewedFile(sessionID: UUID, scope: ReviewScope, filePath: String) throws { try refuse() }
    public func saveAttributionSession(_ snapshot: AttributionSessionSnapshot) throws { try refuse() }
    public func saveAttributedCommits(_ commits: [AttributedCommit], links: [AttributedCommitLink]) throws { try refuse() }
    public func saveAttributedCommitLinks(_ links: [AttributedCommitLink]) throws { try refuse() }
    public func deleteAllCommitAttribution() throws { try refuse() }
}
