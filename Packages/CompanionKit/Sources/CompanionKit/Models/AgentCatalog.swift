import Foundation
import SessionKit

/// Models and effort levels a Mac offers per agent. Sent by the Mac in every
/// fleet snapshot; the phone has no way to discover them itself.
public struct AgentCatalog: Hashable, Codable, Sendable {
    public struct Entry: Hashable, Codable, Sendable {
        public var models: [String]
        public var defaultModel: String
        public var effortLevels: [AgentEffort]
        public var defaultEffort: AgentEffort?
        public var effortLabels: [AgentEffort: String]

        public init(
            models: [String],
            defaultModel: String,
            effortLevels: [AgentEffort],
            defaultEffort: AgentEffort?,
            effortLabels: [AgentEffort: String] = [:]
        ) {
            self.models = models
            self.defaultModel = defaultModel
            self.effortLevels = effortLevels
            self.defaultEffort = defaultEffort
            self.effortLabels = effortLabels
        }
    }

    public var entries: [AgentKind: Entry]

    public init(entries: [AgentKind: Entry]) {
        self.entries = entries
    }

    public func entry(for agent: AgentKind) -> Entry {
        entries[agent] ?? Entry(models: [], defaultModel: "", effortLevels: [], defaultEffort: nil)
    }

    public func effortLabel(_ level: AgentEffort, agent: AgentKind) -> String {
        entry(for: agent).effortLabels[level] ?? level.displayName
    }

    /// A copy of the Mac's static fallback lists, for the demo data and for
    /// previews.
    public static let fallback = AgentCatalog(entries: [
        .claudeCode: Entry(
            models: ["sonnet", "opus", "haiku", "fable", "best", "opusplan"],
            defaultModel: "sonnet",
            effortLevels: [.low, .medium, .high, .xhigh, .max],
            defaultEffort: .medium
        ),
        .codexCLI: Entry(
            models: ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini"],
            defaultModel: "gpt-5.6-sol",
            effortLevels: [.minimal, .low, .medium, .high, .xhigh, .max, .ultra],
            defaultEffort: .medium,
            effortLabels: [.xhigh: "Extra High"]
        ),
        .openCode: Entry(
            models: [
                "opencode/big-pickle",
                "opencode/deepseek-v4-flash-free",
                "opencode/nemotron-3-ultra-free",
                "opencode-go/deepseek-v4-pro",
                "opencode-go/glm-5.3",
            ],
            defaultModel: "opencode/big-pickle",
            effortLevels: [],
            defaultEffort: nil
        ),
        .antigravity: Entry(
            models: ["gemini-3.7-flash-high", "gemini-3.7-flash-medium", "gemini-3.1-pro-high", "gemini-3.1-pro-low"],
            defaultModel: "gemini-3.7-flash-high",
            effortLevels: [.low, .medium, .high],
            defaultEffort: .medium
        ),
    ])
}

/// Mirrors SettingsKit's `OpenCodeSubscription`, which isn't shared with iOS.
public enum OpenCodeSubscription: String, CaseIterable, Identifiable, Codable, Sendable {
    case none
    case zen
    case go

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .none: "None"
        case .zen: "OpenCode Zen"
        case .go: "OpenCode Go"
        }
    }
}

/// What the create-session sheet sends to the Mac.
public struct NewSessionRequest: Hashable, Codable, Sendable {
    public var goal: String
    public var projectID: UUID?
    public var agent: AgentKind
    public var model: String
    public var effort: AgentEffort?
    public var createWorktree: Bool
    public var fetchFirst: Bool
    public var openCodeSubscription: OpenCodeSubscription

    public init(
        goal: String,
        projectID: UUID?,
        agent: AgentKind,
        model: String,
        effort: AgentEffort?,
        createWorktree: Bool,
        fetchFirst: Bool,
        openCodeSubscription: OpenCodeSubscription
    ) {
        self.goal = goal
        self.projectID = projectID
        self.agent = agent
        self.model = model
        self.effort = effort
        self.createWorktree = createWorktree
        self.fetchFirst = fetchFirst
        self.openCodeSubscription = openCodeSubscription
    }
}

public struct HandoffRequest: Hashable, Codable, Sendable {
    public var agent: AgentKind
    public var model: String
    public var effort: AgentEffort?
    public var note: String

    public init(agent: AgentKind, model: String, effort: AgentEffort?, note: String) {
        self.agent = agent
        self.model = model
        self.effort = effort
        self.note = note
    }
}
