import XCTest
import SessionKit
import ProcessKit
import GitKit
import PersistenceKit
import SettingsKit
import TerminalKit
import HooksKit
@testable import Flotilla

struct AppLayerExecutableLocator: ExecutableLocating {
    let executable: URL?
    let tmuxExecutable: URL?

    init(executable: URL?, tmuxExecutable: URL? = nil) {
        self.executable = executable
        self.tmuxExecutable = tmuxExecutable
    }

    func locate(_ name: String) -> URL? {
        if name == "tmux" { return tmuxExecutable }
        return executable
    }
}

/// Deterministic server-health verdicts: the real probe shells out to the
/// machine's actual tmux server, whose state must never decide a test.
final class AppLayerTmuxServerProbe: TmuxServerProbing, @unchecked Sendable {
    var usable: Bool
    private(set) var probeCount = 0

    init(usable: Bool) {
        self.usable = usable
    }

    func serverIsUsable(tmuxExecutable: URL) -> Bool {
        probeCount += 1
        return usable
    }
}

struct StubConversationOwnershipChecker: AgentConversationOwnershipChecking {
    let isActive: Bool

    func isConversationActive(agent: AgentKind, conversationID: String) -> Bool {
        isActive
    }
}

struct SelectiveExecutableLocator: ExecutableLocating {
    let availableNames: Set<String>

    func locate(_ name: String) -> URL? {
        availableNames.contains(name) ? URL(fileURLWithPath: "/usr/bin/env") : nil
    }
}

final class RecordingProcessFactory: PTYProcessCreating, @unchecked Sendable {
    var shouldFailToStart = false
    private(set) var processes: [MockPTYProcess] = []

    func makeProcess() -> any PTYProcessProtocol {
        let process = MockPTYProcess()
        process.echoInputToOutput = true
        process.shouldFailToStart = shouldFailToStart
        processes.append(process)
        return process
    }
}

final class MockTmuxClientProbe: TmuxClientProbing, @unchecked Sendable {
    var stubbedSizes: [String: PTYSize] = [:]
    private let lock = NSLock()
    private var _clientSizeCalls: [(sessionName: String, executable: URL)] = []
    private var _refreshClientCalls: [(sessionName: String, executable: URL)] = []

    var clientSizeCalls: [(sessionName: String, executable: URL)] {
        lock.lock()
        defer { lock.unlock() }
        return _clientSizeCalls
    }

    var refreshClientCalls: [(sessionName: String, executable: URL)] {
        lock.lock()
        defer { lock.unlock() }
        return _refreshClientCalls
    }

    /// Sizes returned for the first N probes of a session, before
    /// `stubbedSizes` takes over — models tmux catching up asynchronously
    /// after a `SIGWINCH` rather than answering correctly on the first ask.
    var settlingSizes: [String: [PTYSize]] = [:]

    func clientSize(sessionNamed name: String, tmuxExecutable: URL) -> PTYSize? {
        lock.lock()
        _clientSizeCalls.append((name, tmuxExecutable))
        if var queued = settlingSizes[name], !queued.isEmpty {
            let next = queued.removeFirst()
            settlingSizes[name] = queued
            lock.unlock()
            return next
        }
        lock.unlock()
        return stubbedSizes[name]
    }

    func refreshClient(sessionNamed name: String, tmuxExecutable: URL) {
        lock.lock()
        _refreshClientCalls.append((name, tmuxExecutable))
        lock.unlock()
    }
}

final class MockTmuxSessionTerminator: TmuxSessionTerminating, @unchecked Sendable {
    var killedSessions: [String] = []
    var stubbedSessions: [String] = []

    func killSession(named name: String, tmuxExecutable: URL) {
        killedSessions.append(name)
    }

    func listSessions(tmuxExecutable: URL) -> [String] {
        stubbedSessions
    }
}

final class RecordingTmuxGoalDeliverer: TmuxGoalDelivering, @unchecked Sendable {
    enum Failure: LocalizedError {
        case rejected

        var errorDescription: String? { "tmux rejected the message" }
    }

    var shouldFail = false
    private(set) var deliveries: [(goal: String, sessionName: String, executable: URL)] = []

    func deliverGoal(_ goal: String, toSessionNamed name: String, tmuxExecutable: URL) throws {
        if shouldFail { throw Failure.rejected }
        deliveries.append((goal, name, tmuxExecutable))
    }
}

/// Forwards to GRDB; set `deleteError` to exercise durable-delete failure paths.
final class ControllableSessionRepository: SessionRepository, @unchecked Sendable {
    let inner: GRDBSessionRepository
    var deleteError: Error?

    init(inner: GRDBSessionRepository? = nil) throws {
        self.inner = try inner ?? GRDBSessionRepository()
    }

    func loadAll() throws -> (projects: [Project], sessions: [Session]) { try inner.loadAll() }
    func save(_ project: Project) throws { try inner.save(project) }
    func save(_ session: Session) throws { try inner.save(session) }
    func delete(sessionID: UUID) throws {
        if let deleteError { throw deleteError }
        try inner.delete(sessionID: sessionID)
    }
    func delete(projectID: UUID) throws { try inner.delete(projectID: projectID) }
    func loadScrollback(sessionID: UUID) -> Data? { inner.loadScrollback(sessionID: sessionID) }
    func updateScrollback(sessionID: UUID, scrollback: Data) throws {
        try inner.updateScrollback(sessionID: sessionID, scrollback: scrollback)
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
    func deleteReviewComments(sessionID: UUID) throws {
        try inner.deleteReviewComments(sessionID: sessionID)
    }
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
