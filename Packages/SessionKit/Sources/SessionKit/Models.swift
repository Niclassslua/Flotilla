import Foundation

public enum AgentKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case claudeCode
    case codexCLI
    case geminiCLI

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codexCLI: return "Codex CLI"
        case .geminiCLI: return "Gemini CLI"
        }
    }
}

public enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case working
    case idle
    case waitingForInput
    case finished
    case crashed
}

public enum CheckoutMode: String, Codable, Sendable {
    case mainCheckout
    case newWorktree
}

public struct WorktreeInfo: Codable, Hashable, Sendable {
    public var branchName: String
    public var worktreePath: URL
    public var baseCheckoutPath: URL

    public init(branchName: String, worktreePath: URL, baseCheckoutPath: URL) {
        self.branchName = branchName
        self.worktreePath = worktreePath
        self.baseCheckoutPath = baseCheckoutPath
    }
}

public struct Project: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var rootPath: URL

    public init(id: UUID = UUID(), name: String, rootPath: URL) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
    }
}

public struct Session: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var goal: String
    public var agent: AgentKind
    /// `nil` for a general/standalone session not tied to any project.
    public var projectID: UUID?
    public var workingDirectory: URL
    public var worktree: WorktreeInfo?
    public var status: SessionStatus
    /// Raw PTY byte stream retained across launches and replayed into
    /// SwiftTerm. Capped by the app before persistence.
    public var terminalScrollback: Data
    public var createdAt: Date
    public var lastActiveAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        goal: String,
        agent: AgentKind,
        projectID: UUID?,
        workingDirectory: URL,
        worktree: WorktreeInfo? = nil,
        status: SessionStatus = .idle,
        terminalScrollback: Data = Data(),
        createdAt: Date = Date(),
        lastActiveAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.goal = goal
        self.agent = agent
        self.projectID = projectID
        self.workingDirectory = workingDirectory
        self.worktree = worktree
        self.status = status
        self.terminalScrollback = terminalScrollback
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
    }
}
