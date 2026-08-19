import Foundation

public enum AgentKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case claudeCode
    case codexCLI
    case openCode
    case antigravity

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codexCLI: return "Codex CLI"
        case .openCode: return "OpenCode"
        case .antigravity: return "Antigravity"
        }
    }

    /// Whether the CLI accepts a reasoning-effort flag at all. OpenCode has
    /// no equivalent knob — effort is a property of the upstream model there,
    /// not something the CLI exposes. Which *levels* an agent accepts (and
    /// which of those a given model accepts) is `AgentEffortCatalog`'s job.
    public var supportsEffortSelection: Bool {
        switch self {
        case .claudeCode, .codexCLI, .antigravity: true
        case .openCode: false
        }
    }
}

/// The union of reasoning-effort levels across the supported CLIs, ordered
/// from cheapest to deepest.
///
/// No single agent accepts all of them: Claude Code's `--effort` tops out at
/// `max` and has no `minimal`/`ultra`, while Codex's `model_reasoning_effort`
/// accepts the full set but restricts it further *per model*. `AgentEffort` is
/// therefore only the vocabulary — availability comes from
/// `AgentKit.AgentEffortCatalog`, and the human-facing name for a level is
/// agent-specific (`AgentEffortCatalog.label(for:agent:)`); `displayName` is
/// the neutral fallback used for persisted values and accessibility.
public enum AgentEffort: String, Codable, CaseIterable, Sendable, Identifiable {
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    public var id: String { rawValue }

    /// Rank along the cheap → deep ramp. Stable across agents, so a level can
    /// be clamped into another agent's or model's supported set.
    public var rank: Int {
        AgentEffort.allCases.firstIndex(of: self) ?? 0
    }

    public var displayName: String {
        switch self {
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "X-High"
        case .max: "Max"
        case .ultra: "Ultra"
        }
    }
}

public enum SessionStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case working
    case idle
    case waitingForInput
    case ready
    case finished
    case crashed

    public var id: String { rawValue }
}

public enum CheckoutMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case mainCheckout
    case newWorktree

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mainCheckout: return "Main Checkout"
        case .newWorktree: return "New Worktree"
        }
    }
}

public enum KanbanColumnMode: String, Codable, CaseIterable, Sendable {
    case status
    case agents
    case workflow
    case custom
}

public enum WorkflowStage: String, Codable, CaseIterable, Sendable, Identifiable {
    case backlog
    case inProgress
    case review
    case merged

    public var id: String { rawValue }
}

public struct KanbanColumn: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var title: String
    public var order: Int
    public var statusFilter: SessionStatus?
    public var agentFilter: AgentKind?
    public var workflowStageFilter: WorkflowStage?
    public var color: String?

    public init(
        id: UUID = UUID(),
        title: String,
        order: Int,
        statusFilter: SessionStatus? = nil,
        agentFilter: AgentKind? = nil,
        workflowStageFilter: WorkflowStage? = nil,
        color: String? = nil
    ) {
        self.id = id
        self.title = title
        self.order = order
        self.statusFilter = statusFilter
        self.agentFilter = agentFilter
        self.workflowStageFilter = workflowStageFilter
        self.color = color
    }

    /// A fixed identity for one of the built-in columns.
    ///
    /// The board view builds its columns by calling the factories below on
    /// every SwiftUI body evaluation, and `ForEach` keys off `id`. With the
    /// default `UUID()` every evaluation produced columns SwiftUI had never
    /// seen, so it tore down and rebuilt every column, card and hosted
    /// terminal view instead of diffing them — which froze the Kanban layout.
    /// Deriving the id from the column's kind keeps it stable across calls
    /// without hardcoding opaque literals.
    private static func builtInID(kind: UInt8, index: UInt8) -> UUID {
        UUID(uuid: (0xF1, 0x07, 0x11, 0x11, 0x00, 0x00, 0x40, 0x00, 0xA0, 0x00, 0x00, 0x00, 0x00, 0x00, kind, index))
    }

    public static func defaultStatusColumns() -> [KanbanColumn] {
        [
            KanbanColumn(id: builtInID(kind: 1, index: 0), title: "Working", order: 0, statusFilter: .working),
            KanbanColumn(id: builtInID(kind: 1, index: 1), title: "Waiting", order: 1, statusFilter: .waitingForInput),
            KanbanColumn(id: builtInID(kind: 1, index: 2), title: "Ready", order: 2, statusFilter: .ready),
            KanbanColumn(id: builtInID(kind: 1, index: 3), title: "Idle", order: 3, statusFilter: .idle),
            KanbanColumn(id: builtInID(kind: 1, index: 4), title: "Finished", order: 4, statusFilter: .finished),
            KanbanColumn(id: builtInID(kind: 1, index: 5), title: "Crashed", order: 5, statusFilter: .crashed),
        ]
    }

    public static func defaultAgentColumns() -> [KanbanColumn] {
        [
            KanbanColumn(id: builtInID(kind: 2, index: 0), title: "Claude Code", order: 0, agentFilter: .claudeCode),
            KanbanColumn(id: builtInID(kind: 2, index: 1), title: "Codex CLI", order: 1, agentFilter: .codexCLI),
            KanbanColumn(id: builtInID(kind: 2, index: 2), title: "OpenCode", order: 2, agentFilter: .openCode),
            KanbanColumn(id: builtInID(kind: 2, index: 3), title: "Antigravity", order: 3, agentFilter: .antigravity),
        ]
    }

    public static func defaultWorkflowColumns() -> [KanbanColumn] {
        [
            KanbanColumn(id: builtInID(kind: 3, index: 0), title: "Backlog", order: 0, workflowStageFilter: .backlog),
            KanbanColumn(id: builtInID(kind: 3, index: 1), title: "In Progress", order: 1, workflowStageFilter: .inProgress),
            KanbanColumn(id: builtInID(kind: 3, index: 2), title: "Review", order: 2, workflowStageFilter: .review),
            KanbanColumn(id: builtInID(kind: 3, index: 3), title: "Merged", order: 3, workflowStageFilter: .merged),
        ]
    }
}

public struct KanbanBoard: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var projectID: UUID?
    public var name: String
    public var columnMode: KanbanColumnMode
    public var customColumns: [KanbanColumn]
    public var cardOrder: [String: Int]
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID?,
        name: String,
        columnMode: KanbanColumnMode = .status,
        customColumns: [KanbanColumn] = [],
        cardOrder: [String: Int] = [:],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.columnMode = columnMode
        self.customColumns = customColumns
        self.cardOrder = cardOrder
        self.updatedAt = updatedAt
    }
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
    /// `nil` uses the agent's own default model; otherwise passed as `--model <value>`.
    public var model: String?
    /// Per-session reasoning/compute effort. `nil` preserves the CLI's own default.
    public var effort: AgentEffort?
    /// `nil` for a general/standalone session not tied to any project.
    public var projectID: UUID?
    public var workingDirectory: URL
    public var worktree: WorktreeInfo?
    public var status: SessionStatus
    /// Kanban board column assignment (for custom column mode)
    public var kanbanColumnID: UUID?
    /// Workflow stage (for workflow column mode)
    public var workflowStage: WorkflowStage?
    /// Native agent session ID for session resumption across launches
    public var agentSessionID: String?
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
        model: String? = nil,
        effort: AgentEffort? = nil,
        projectID: UUID?,
        workingDirectory: URL,
        worktree: WorktreeInfo? = nil,
        status: SessionStatus = .idle,
        kanbanColumnID: UUID? = nil,
        workflowStage: WorkflowStage? = nil,
        agentSessionID: String? = nil,
        terminalScrollback: Data = Data(),
        createdAt: Date = Date(),
        lastActiveAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.goal = goal
        self.agent = agent
        self.model = model
        self.effort = effort
        self.projectID = projectID
        self.workingDirectory = workingDirectory
        self.worktree = worktree
        self.status = status
        self.kanbanColumnID = kanbanColumnID
        self.workflowStage = workflowStage
        self.agentSessionID = agentSessionID
        self.terminalScrollback = terminalScrollback
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
    }
}
