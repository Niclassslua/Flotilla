import Foundation
import SessionKit

/// A session discovered from an external coding agent's native storage or API
/// (such as Claude Code, OpenCode, Codex CLI, or Antigravity).
public struct DiscoveredAgentSession: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let workingDirectory: URL?
    public let lastActiveAt: Date?
    public let agent: AgentKind
    public let isCustomTitle: Bool

    public init(
        id: String,
        title: String,
        workingDirectory: URL? = nil,
        lastActiveAt: Date? = nil,
        agent: AgentKind,
        isCustomTitle: Bool = false
    ) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.lastActiveAt = lastActiveAt
        self.agent = agent
        self.isCustomTitle = isCustomTitle
    }
}

/// Protocol for querying an agent's native session index or REST API.
public protocol AgentSessionProviding: Sendable {
    var agent: AgentKind { get }

    /// Returns all known sessions for this agent on the local machine.
    func fetchSessions() async throws -> [DiscoveredAgentSession]

    /// Resolves the newest/active session for a given working directory (e.g. worktree or project root),
    /// optionally filtered by a minimum modification timestamp (`since`).
    func fetchLatestSession(for workingDirectory: URL, since: Date?) async throws -> DiscoveredAgentSession?
}

extension AgentSessionProviding {
    public func fetchLatestSession(for workingDirectory: URL) async throws -> DiscoveredAgentSession? {
        try await fetchLatestSession(for: workingDirectory, since: nil)
    }
}
