import Foundation

public enum AgentKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case claudeCode
    case codexCLI
    case openCode
    case antigravity
    case cursorAgent

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codexCLI: return "Codex CLI"
        case .openCode: return "OpenCode"
        case .antigravity: return "Antigravity"
        case .cursorAgent: return "Cursor Agent"
        }
    }

    /// Whether the CLI accepts a reasoning-effort flag at all. OpenCode has
    /// no equivalent knob — effort is a property of the upstream model there,
    /// not something the CLI exposes. Which *levels* an agent accepts (and
    /// which of those a given model accepts) is `AgentEffortCatalog`'s job.
    public var supportsEffortSelection: Bool {
        switch self {
        case .claudeCode, .codexCLI, .antigravity, .cursorAgent: true
        case .openCode: false
        }
    }

    /// Effort is chosen in the UI and written into the model slug. These CLIs
    /// have no `--effort` flag — Antigravity and Cursor Agent both do this.
    public var bakesEffortIntoModelSlug: Bool {
        switch self {
        case .antigravity, .cursorAgent: true
        case .claudeCode, .codexCLI, .openCode: false
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

/// Whether a session starts in full-autonomy mode or in planning mode.
///
/// Planning mode constrains the agent to reading and proposing rather than
/// making changes. Each CLI expresses this differently: Claude Code uses
/// `--permission-mode plan`, Antigravity uses `--mode plan`, OpenCode uses
/// `--agent plan`, and Codex CLI receives a `/plan` prefix on its initial
/// goal via `initialInput`.
public enum SessionMode: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case act
    case plan

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .act: "Act"
        case .plan: "Plan"
        }
    }

    public var symbolName: String {
        switch self {
        case .act: "bolt.fill"
        case .plan: "doc.text.magnifyingglass"
        }
    }

    public var explanation: String {
        switch self {
        case .act: "The agent can read files and make changes."
        case .plan: "Explore and propose a plan before making changes."
        }
    }

    /// True when the goal field contains a bare `/plan` that should surface
    /// as a quick-action suggestion in the mode chip area.
    public static func suggestsPlanCommand(in goal: String) -> Bool {
        goal.trimmingCharacters(in: .whitespacesAndNewlines) == "/plan"
    }

    /// Strips a leading `/plan ` prefix from the goal and returns the clean
    /// objective, or `nil` if no `/plan` prefix is present.
    public static func planCommandGoal(in goal: String) -> String? {
        let t = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("/plan ") { return String(t.dropFirst(6)) }
        return nil
    }
}

public enum SessionStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case working
    case waitingForInput
    /// The agent's turn ended, or its process exited cleanly, and the work is
    /// there to look at. Absorbs what used to be split across `idle` and
    /// `finished`. Not terminal: an agent that resumes moves back to `working`.
    case readyForReview
    case crashed

    public var id: String { rawValue }
}

/// The action a blocked agent needs from the user. Kept separate from
/// `SessionStatus` so status-based boards can continue grouping every
/// blocked session under `waitingForInput` while the UI says what is needed.
public enum SessionWaitingReason: String, Codable, Sendable, CaseIterable, Identifiable {
    case permission
    case question
    case planApproval

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
            // Sessions with no status yet ("Unstarted") deliberately have no
            // column: they don't appear on the board.
            KanbanColumn(id: builtInID(kind: 1, index: 0), title: "Working", order: 0, statusFilter: .working),
            KanbanColumn(id: builtInID(kind: 1, index: 1), title: "Waiting", order: 1, statusFilter: .waitingForInput),
            KanbanColumn(id: builtInID(kind: 1, index: 2), title: "Ready for Review", order: 2, statusFilter: .readyForReview),
            KanbanColumn(id: builtInID(kind: 1, index: 5), title: "Crashed", order: 3, statusFilter: .crashed),
        ]
    }

    public static func defaultAgentColumns() -> [KanbanColumn] {
        [
            KanbanColumn(id: builtInID(kind: 2, index: 0), title: "Claude Code", order: 0, agentFilter: .claudeCode),
            KanbanColumn(id: builtInID(kind: 2, index: 1), title: "Codex CLI", order: 1, agentFilter: .codexCLI),
            KanbanColumn(id: builtInID(kind: 2, index: 2), title: "OpenCode", order: 2, agentFilter: .openCode),
            KanbanColumn(id: builtInID(kind: 2, index: 3), title: "Antigravity", order: 3, agentFilter: .antigravity),
            KanbanColumn(id: builtInID(kind: 2, index: 4), title: "Cursor Agent", order: 4, agentFilter: .cursorAgent),
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

public enum ProjectIcon: Codable, Hashable, Sendable {
    case symbol(name: String)
    case emoji(String)
    case custom(data: Data)
}

public struct Project: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var rootPath: URL
    public var icon: ProjectIcon?
    public var accentColor: String?

    public init(id: UUID = UUID(), name: String, rootPath: URL, icon: ProjectIcon? = nil, accentColor: String? = nil) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.icon = icon
        self.accentColor = accentColor
    }
}

/// A handoff that has written the destination agent's transcript and relaunched
/// the session, but whose destination has not yet proved it can run.
///
/// It exists so the source transcript can outlive the switch. Deleting the
/// source at the moment of the move would make a destination that fails to
/// start — a missing binary, an expired login — unrecoverable; keeping this
/// record means the session can be put back exactly as it was.
public struct PendingHandoff: Codable, Hashable, Sendable {
    /// The agent the session is returned to if the destination never starts.
    public let sourceAgent: AgentKind
    /// That agent's own session id. Needed to put the session back, and to
    /// find the source's sidecar state once the move is confirmed — by then
    /// `agentSessionID` names the destination and no longer identifies it.
    public let sourceSessionID: String
    /// The still-intact transcript that agent would resume from.
    public let sourceTranscriptPath: URL
    /// The model and effort the session was running under.
    ///
    /// Both are cleared by a handoff — they name a *specific agent's* model and
    /// reasoning levels, and mean nothing to another vendor — so they are kept
    /// here to be put back if the move is rolled back.
    public let sourceModel: String?
    public let sourceEffort: AgentEffort?
    public let startedAt: Date

    public init(
        sourceAgent: AgentKind,
        sourceSessionID: String,
        sourceTranscriptPath: URL,
        sourceModel: String? = nil,
        sourceEffort: AgentEffort? = nil,
        startedAt: Date = Date()
    ) {
        self.sourceAgent = sourceAgent
        self.sourceSessionID = sourceSessionID
        self.sourceTranscriptPath = sourceTranscriptPath
        self.sourceModel = sourceModel
        self.sourceEffort = sourceEffort
        self.startedAt = startedAt
    }
}

/// The GitHub issue a session was started from. Enough to show and link it;
/// the issue's body was delivered once, as the goal.
public struct IssueLink: Codable, Hashable, Sendable {
    public var number: Int
    public var title: String
    public var url: URL

    public init(number: Int, title: String, url: URL) {
        self.number = number
        self.title = title
        self.url = url
    }

    /// "#123 Fix login crash" — the session title an issue session starts with.
    public var sessionTitle: String {
        "#\(number) \(title)"
    }

    /// `flotilla/issue-123-fix-login-crash-<8hex>`: the issue number survives
    /// the slug's truncation, so the branch still names the issue it fixes.
    public func branchName(uuid: UUID = UUID()) -> String {
        BranchNaming.generate(from: "issue \(number) \(title)", uuid: uuid)
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
    /// `nil` until the agent has been observed doing or finishing anything —
    /// a session that was created but whose process has produced no status
    /// signal yet. Once set it never returns to `nil`.
    public var status: SessionStatus?
    /// More specific meaning for `waitingForInput`; always `nil` in every
    /// other status.
    public var waitingReason: SessionWaitingReason?
    /// When `status` last changed. `nil` for a session created before this
    /// field existed and never transitioned since — Home's Needs you widget
    /// falls back to `lastActiveAt` in that case. Set alongside `status` by
    /// `SessionStatusMachine.transition` and `AppStore.applyObservedStatus`,
    /// never directly.
    public var statusChangedAt: Date?
    /// Kanban board column assignment (for custom column mode)
    public var kanbanColumnID: UUID?
    /// Workflow stage (for workflow column mode)
    public var workflowStage: WorkflowStage?
    /// The mode the session was started in. `.act` (default) lets the agent
    /// make changes; `.plan` restricts it to reading and proposing.
    /// Stored so a manual restart replays the same flag.
    public var startingMode: SessionMode
    /// Native agent session ID for session resumption across launches
    public var agentSessionID: String?
    /// Where the current agent keeps this session's transcript.
    ///
    /// Recorded rather than rediscovered: several sessions can share a working
    /// directory, so "the newest transcript here" resolves to the wrong
    /// conversation. `nil` until a handoff writes one.
    public var nativeTranscriptPath: URL?
    /// Set while a handoff is on probation; `nil` at rest.
    public var pendingHandoff: PendingHandoff?
    /// The GitHub issue this session was started from, if any.
    public var linkedIssue: IssueLink?
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
        status: SessionStatus? = nil,
        waitingReason: SessionWaitingReason? = nil,
        statusChangedAt: Date? = nil,
        kanbanColumnID: UUID? = nil,
        workflowStage: WorkflowStage? = nil,
        startingMode: SessionMode = .act,
        agentSessionID: String? = nil,
        nativeTranscriptPath: URL? = nil,
        pendingHandoff: PendingHandoff? = nil,
        linkedIssue: IssueLink? = nil,
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
        self.waitingReason = status == .waitingForInput ? waitingReason : nil
        self.statusChangedAt = statusChangedAt
        self.kanbanColumnID = kanbanColumnID
        self.workflowStage = workflowStage
        self.startingMode = startingMode
        self.agentSessionID = agentSessionID
        self.nativeTranscriptPath = nativeTranscriptPath
        self.pendingHandoff = pendingHandoff
        self.linkedIssue = linkedIssue
        self.terminalScrollback = terminalScrollback
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
    }
}
