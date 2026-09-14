import Foundation
import SessionKit

/// One selectable model option in the companion catalog.
public struct ModelOption: Hashable, Codable, Sendable, Identifiable {
    public var slug: String
    public var displayName: String?
    public var description: String?

    public var id: String { slug }

    public init(slug: String, displayName: String? = nil, description: String? = nil) {
        self.slug = slug
        self.displayName = displayName
        self.description = description
    }
}

/// One Antigravity model group for the companion catalog, grouping variant
/// slugs (e.g. `gemini-3.7-flash-{low,medium,high}`) under one base display name.
public struct AntigravityGroupOption: Hashable, Codable, Sendable, Identifiable {
    public var baseSlug: String
    public var displayName: String
    public var variants: [AgentEffort: String]
    public var soleSlug: String?

    public var id: String { baseSlug }

    public init(
        baseSlug: String,
        displayName: String,
        variants: [AgentEffort: String] = [:],
        soleSlug: String? = nil
    ) {
        self.baseSlug = baseSlug
        self.displayName = displayName
        self.variants = variants
        self.soleSlug = soleSlug
    }

    public func resolvedSlug(for effort: AgentEffort?) -> String? {
        if variants.isEmpty { return soleSlug }
        if let effort, let exact = variants[effort] { return exact }
        guard let effort else {
            return variants[.medium] ?? variants.values.first
        }
        return variants.min { lhs, rhs in
            abs(lhs.key.rank - effort.rank) < abs(rhs.key.rank - effort.rank)
        }?.value
    }
}

/// Models and effort levels a Mac offers per agent. Sent by the Mac in every
/// fleet snapshot; the phone has no way to discover them itself.
public struct AgentCatalog: Hashable, Codable, Sendable {
    public struct Entry: Hashable, Codable, Sendable {
        public var models: [ModelOption]
        public var defaultModel: String
        public var effortLevels: [AgentEffort]
        public var defaultEffort: AgentEffort?
        public var effortLabels: [AgentEffort: String]
        public var antigravityGroups: [AntigravityGroupOption]

        public init(
            models: [ModelOption],
            defaultModel: String,
            effortLevels: [AgentEffort],
            defaultEffort: AgentEffort?,
            effortLabels: [AgentEffort: String] = [:],
            antigravityGroups: [AntigravityGroupOption] = []
        ) {
            self.models = models
            self.defaultModel = defaultModel
            self.effortLevels = effortLevels
            self.defaultEffort = defaultEffort
            self.effortLabels = effortLabels
            self.antigravityGroups = antigravityGroups
        }

        public init(
            modelSlugs: [String],
            defaultModel: String,
            effortLevels: [AgentEffort],
            defaultEffort: AgentEffort?,
            effortLabels: [AgentEffort: String] = [:],
            antigravityGroups: [AntigravityGroupOption] = []
        ) {
            self.models = modelSlugs.map { ModelOption(slug: $0) }
            self.defaultModel = defaultModel
            self.effortLevels = effortLevels
            self.defaultEffort = defaultEffort
            self.effortLabels = effortLabels
            self.antigravityGroups = antigravityGroups
        }

        public var modelSlugs: [String] {
            models.map(\.slug)
        }

        enum CodingKeys: String, CodingKey {
            case models
            case defaultModel
            case effortLevels
            case defaultEffort
            case effortLabels
            case antigravityGroups
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            defaultModel = try container.decode(String.self, forKey: .defaultModel)
            effortLevels = try container.decode([AgentEffort].self, forKey: .effortLevels)
            defaultEffort = try container.decodeIfPresent(AgentEffort.self, forKey: .defaultEffort)
            effortLabels = try container.decodeIfPresent([AgentEffort: String].self, forKey: .effortLabels) ?? [:]
            antigravityGroups = try container.decodeIfPresent([AntigravityGroupOption].self, forKey: .antigravityGroups) ?? []

            if let options = try? container.decode([ModelOption].self, forKey: .models) {
                models = options
            } else if let strings = try? container.decode([String].self, forKey: .models) {
                models = strings.map { ModelOption(slug: $0) }
            } else {
                models = []
            }
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
            models: [
                ModelOption(slug: "sonnet", displayName: "Claude 3.7 Sonnet"),
                ModelOption(slug: "opus", displayName: "Claude 3.5 Opus"),
                ModelOption(slug: "haiku", displayName: "Claude 3.5 Haiku"),
                ModelOption(slug: "fable", displayName: "Claude Fable"),
                ModelOption(slug: "best", displayName: "Best Available"),
                ModelOption(slug: "opusplan", displayName: "Opus Plan"),
            ],
            defaultModel: "sonnet",
            effortLevels: [.low, .medium, .high, .xhigh, .max],
            defaultEffort: .medium
        ),
        .codexCLI: Entry(
            models: [
                ModelOption(slug: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", description: "Latest frontier agentic coding model."),
                ModelOption(slug: "gpt-5.6-terra", displayName: "GPT-5.6 Terra"),
                ModelOption(slug: "gpt-5.6-luna", displayName: "GPT-5.6 Luna"),
                ModelOption(slug: "gpt-5.5", displayName: "GPT-5.5"),
                ModelOption(slug: "gpt-5.4", displayName: "GPT-5.4"),
                ModelOption(slug: "gpt-5.4-mini", displayName: "GPT-5.4 Mini"),
            ],
            defaultModel: "gpt-5.6-sol",
            effortLevels: [.minimal, .low, .medium, .high, .xhigh, .max, .ultra],
            defaultEffort: .medium,
            effortLabels: [.xhigh: "Extra High"]
        ),
        .openCode: Entry(
            models: [
                ModelOption(slug: "opencode/big-pickle", displayName: "Big Pickle"),
                ModelOption(slug: "opencode/deepseek-v4-flash-free", displayName: "DeepSeek V4 Flash Free"),
                ModelOption(slug: "opencode/nemotron-3-ultra-free", displayName: "Nemotron 3 Ultra Free"),
                ModelOption(slug: "opencode-go/deepseek-v4-pro", displayName: "DeepSeek V4 Pro"),
                ModelOption(slug: "opencode-go/glm-5.3", displayName: "GLM 5.3"),
            ],
            defaultModel: "opencode/big-pickle",
            effortLevels: [],
            defaultEffort: nil
        ),
        .antigravity: Entry(
            models: [
                ModelOption(slug: "gemini-3.7-flash-high", displayName: "Gemini 3.7 Flash (High)"),
                ModelOption(slug: "gemini-3.7-flash-medium", displayName: "Gemini 3.7 Flash (Medium)"),
                ModelOption(slug: "gemini-3.1-pro-high", displayName: "Gemini 3.1 Pro (High)"),
                ModelOption(slug: "gemini-3.1-pro-low", displayName: "Gemini 3.1 Pro (Low)"),
                ModelOption(slug: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6 (Thinking)"),
                ModelOption(slug: "gpt-oss-120b-medium", displayName: "GPT-OSS 120B (Medium)"),
            ],
            defaultModel: "gemini-3.7-flash-high",
            effortLevels: [.low, .medium, .high],
            defaultEffort: .medium,
            antigravityGroups: [
                AntigravityGroupOption(
                    baseSlug: "gemini-3.7-flash",
                    displayName: "Gemini 3.7 Flash",
                    variants: [
                        .high: "gemini-3.7-flash-high",
                        .medium: "gemini-3.7-flash-medium",
                        .low: "gemini-3.7-flash-low",
                    ]
                ),
                AntigravityGroupOption(
                    baseSlug: "gemini-3.1-pro",
                    displayName: "Gemini 3.1 Pro",
                    variants: [
                        .high: "gemini-3.1-pro-high",
                        .low: "gemini-3.1-pro-low",
                    ]
                ),
                AntigravityGroupOption(
                    baseSlug: "claude-sonnet-4-6",
                    displayName: "Claude Sonnet 4.6 (Thinking)",
                    variants: [:],
                    soleSlug: "claude-sonnet-4-6"
                ),
                AntigravityGroupOption(
                    baseSlug: "gpt-oss-120b",
                    displayName: "GPT-OSS 120B",
                    variants: [.medium: "gpt-oss-120b-medium"]
                ),
            ]
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
    public var initialMode: SessionMode
    public var createWorktree: Bool
    public var fetchFirst: Bool
    public var openCodeSubscription: OpenCodeSubscription

    public init(
        goal: String,
        projectID: UUID?,
        agent: AgentKind,
        model: String,
        effort: AgentEffort?,
        initialMode: SessionMode = .act,
        createWorktree: Bool,
        fetchFirst: Bool,
        openCodeSubscription: OpenCodeSubscription
    ) {
        self.goal = goal
        self.projectID = projectID
        self.agent = agent
        self.model = model
        self.effort = effort
        self.initialMode = initialMode
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
