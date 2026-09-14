import Foundation
import SessionKit

/// Models and effort levels a Mac offers per agent.
///
/// On the real phone this arrives from the Mac (AgentKit's `ModelCatalog` and
/// `AgentEffortCatalog` can't run here — they shell out to the CLIs). The
/// prototype carries a static copy of the Mac's fallback lists.
struct AgentCatalog: Sendable {
    struct Entry: Sendable {
        var models: [String]
        var defaultModel: String
        var effortLevels: [AgentEffort]
        var defaultEffort: AgentEffort?
        var effortLabels: [AgentEffort: String] = [:]
    }

    var entries: [AgentKind: Entry]

    func entry(for agent: AgentKind) -> Entry {
        entries[agent] ?? Entry(models: [], defaultModel: "", effortLevels: [], defaultEffort: nil)
    }

    func effortLabel(_ level: AgentEffort, agent: AgentKind) -> String {
        entry(for: agent).effortLabels[level] ?? level.displayName
    }

    static let fallback = AgentCatalog(entries: [
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
enum OpenCodeSubscription: String, CaseIterable, Identifiable, Sendable {
    case none
    case zen
    case go

    var id: Self { self }

    var displayName: String {
        switch self {
        case .none: "None"
        case .zen: "OpenCode Zen"
        case .go: "OpenCode Go"
        }
    }
}

/// What the create-session sheet sends to the Mac.
struct NewSessionRequest: Sendable {
    var goal: String
    var projectID: UUID?
    var agent: AgentKind
    var model: String
    var effort: AgentEffort?
    var createWorktree: Bool
    var fetchFirst: Bool
    var openCodeSubscription: OpenCodeSubscription
}

struct HandoffRequest: Sendable {
    var agent: AgentKind
    var model: String
    var effort: AgentEffort?
    var note: String
}
