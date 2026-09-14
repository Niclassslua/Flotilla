import Foundation
import SessionKit
import ProcessKit
import SettingsKit

public struct FlagSpec: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        case separateTokens     // ["--model", value]
        case joinedWithEquals   // ["--model=value"]
        case bareValue          // [value] — positional
    }
    public var token: String
    public var style: Style

    public init(token: String = "", style: Style = .separateTokens) {
        self.token = token
        self.style = style
    }

    public static func separateTokens(_ token: String) -> FlagSpec {
        FlagSpec(token: token, style: .separateTokens)
    }

    public static func joinedWithEquals(_ token: String) -> FlagSpec {
        FlagSpec(token: token, style: .joinedWithEquals)
    }

    public static var bareValue: FlagSpec {
        FlagSpec(token: "", style: .bareValue)
    }

    public func arguments(for value: String) -> [String] {
        switch style {
        case .separateTokens:
            return token.isEmpty ? [value] : [token, value]
        case .joinedWithEquals:
            return token.isEmpty ? [value] : ["\(token)=\(value)"]
        case .bareValue:
            return [value]
        }
    }
}

public enum ArgumentPlacement: Equatable, Sendable {
    case appendFlags                  // claude / opencode / agy
    case leadingSubcommand(String)    // codex: ["resume", <id>] + rest
}

public enum AgentResumeStrategy: Equatable, Sendable {
    case assignable(assign: FlagSpec, resume: FlagSpec, placement: ArgumentPlacement)
    case discoverable(resume: FlagSpec, placement: ArgumentPlacement)
    case unsupported
}

public struct EffortFlagSpec: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        case flag(FlagSpec)
        case configAssignment(flag: String, key: String)
    }
    public var style: Style

    public init(style: Style) {
        self.style = style
    }

    public static func flag(_ spec: FlagSpec) -> EffortFlagSpec {
        EffortFlagSpec(style: .flag(spec))
    }

    public static func configAssignment(flag: String = "--config", key: String) -> EffortFlagSpec {
        EffortFlagSpec(style: .configAssignment(flag: flag, key: key))
    }

    public func arguments(for effort: AgentEffort) -> [String] {
        switch style {
        case .flag(let spec):
            return spec.arguments(for: effort.rawValue)
        case .configAssignment(let flag, let key):
            return [flag, "\(key)=\"\(effort.rawValue)\""]
        }
    }
}

public struct AgentDescriptor: Equatable, Sendable, Identifiable {
    public var id: AgentKind { kind }
    public let kind: AgentKind
    public let displayName: String
    public let binaryName: String
    public let settingsKey: String
    public let modelFlag: FlagSpec?
    public let effortFlag: EffortFlagSpec?
    public let promptFlag: FlagSpec?
    public let effortLevels: [AgentEffort]
    public let effortLabels: [AgentEffort: String]
    public let fallbackModels: [String]
    public let multilineNewline: Data
    public let resume: AgentResumeStrategy
    public let accessibilityIDPrefix: String

    public init(
        kind: AgentKind,
        displayName: String,
        binaryName: String,
        settingsKey: String,
        modelFlag: FlagSpec? = .separateTokens("--model"),
        effortFlag: EffortFlagSpec? = nil,
        promptFlag: FlagSpec? = nil,
        effortLevels: [AgentEffort] = [],
        effortLabels: [AgentEffort: String] = [:],
        fallbackModels: [String] = [],
        multilineNewline: Data = Data([0x0A]),
        resume: AgentResumeStrategy = .unsupported,
        accessibilityIDPrefix: String
    ) {
        self.kind = kind
        self.displayName = displayName
        self.binaryName = binaryName
        self.settingsKey = settingsKey
        self.modelFlag = modelFlag
        self.effortFlag = effortFlag
        self.promptFlag = promptFlag
        self.effortLevels = effortLevels
        self.effortLabels = effortLabels
        self.fallbackModels = fallbackModels
        self.multilineNewline = multilineNewline
        self.resume = resume
        self.accessibilityIDPrefix = accessibilityIDPrefix
    }

    public var supportsEffort: Bool {
        !effortLevels.isEmpty
    }

    public func effortLabel(for level: AgentEffort) -> String {
        effortLabels[level] ?? level.displayName
    }

    public func invocationHint(for level: AgentEffort) -> String? {
        guard effortLevels.contains(level) else { return nil }
        switch effortFlag?.style {
        case .flag(let spec):
            return "\(binaryName) \(spec.token) \(level.rawValue)"
        case .configAssignment(let flag, let key):
            let shortFlag = flag == "--config" ? "-c" : flag
            return "\(binaryName) \(shortFlag) \(key)=\"\(level.rawValue)\""
        case nil:
            return nil
        }
    }
}

public enum AgentCatalog {
    public static let all: [AgentDescriptor] = [
        claudeCode,
        codexCLI,
        openCode,
        antigravity
    ]

    public static func descriptor(for kind: AgentKind) -> AgentDescriptor {
        switch kind {
        case .claudeCode: claudeCode
        case .codexCLI: codexCLI
        case .openCode: openCode
        case .antigravity: antigravity
        }
    }

    public static let claudeCode = AgentDescriptor(
        kind: .claudeCode,
        displayName: "Claude Code",
        binaryName: "claude",
        settingsKey: "claudeCode",
        modelFlag: .separateTokens("--model"),
        effortFlag: .flag(.separateTokens("--effort")),
        promptFlag: .bareValue,
        effortLevels: [.low, .medium, .high, .xhigh, .max],
        effortLabels: [:],
        fallbackModels: ["sonnet", "opus", "haiku", "fable", "best", "opusplan"],
        multilineNewline: Data([0x1B, 0x0D]),
        resume: .assignable(
            assign: .separateTokens("--session-id"),
            resume: .separateTokens("--resume"),
            placement: .appendFlags
        ),
        accessibilityIDPrefix: "Settings.ClaudeCode"
    )

    public static let codexCLI = AgentDescriptor(
        kind: .codexCLI,
        displayName: "Codex CLI",
        binaryName: "codex",
        settingsKey: "codexCLI",
        modelFlag: .separateTokens("--model"),
        effortFlag: .configAssignment(flag: "--config", key: "model_reasoning_effort"),
        promptFlag: .bareValue,
        effortLevels: [.minimal, .low, .medium, .high, .xhigh, .max, .ultra],
        effortLabels: [.xhigh: "Extra High"],
        fallbackModels: ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini"],
        multilineNewline: Data([0x0A]),
        resume: .discoverable(
            resume: .bareValue,
            placement: .leadingSubcommand("resume")
        ),
        accessibilityIDPrefix: "Settings.CodexCLI"
    )

    public static let openCode = AgentDescriptor(
        kind: .openCode,
        displayName: "OpenCode",
        binaryName: "opencode",
        settingsKey: "openCode",
        modelFlag: .separateTokens("--model"),
        effortFlag: nil,
        promptFlag: .separateTokens("--prompt"),
        effortLevels: [],
        effortLabels: [:],
        fallbackModels: [
            "opencode/nemotron-3-ultra-free",
            "opencode/nemotron-3.5-lightning-free",
            "opencode/big-pickle",
            "opencode/deepseek-v4-flash-free",
            "opencode/hy3-free",
            "opencode/laguna-s-2.1-free",
            "opencode/mimo-v2.5-free",
            "opencode-go/deepseek-v4-flash",
            "opencode-go/deepseek-v4-pro",
            "opencode-go/glm-5.1",
            "opencode-go/glm-5.2",
            "opencode-go/glm-5.3",
            "opencode-go/gpt-5.6-luna",
            "opencode-go/grok-4.5",
            "opencode-go/hy3",
            "opencode-go/kimi-k2.6",
            "opencode-go/kimi-k2.7-code",
            "opencode-go/kimi-k3",
            "opencode-go/mimo-v2.5",
            "opencode-go/mimo-v2.5-pro",
            "opencode-go/minimax-m2.7",
            "opencode-go/minimax-m3",
            "opencode-go/qwen3.6-plus",
            "opencode-go/qwen3.7-max",
            "opencode-go/qwen3.7-plus",
            "opencode-go/qwen3.8-max",
            "openrouter/~anthropic/claude-sonnet-latest",
            "openrouter/~anthropic/claude-opus-latest",
            "openrouter/~anthropic/claude-haiku-latest",
            "openrouter/~openai/gpt-latest",
            "openrouter/~openai/gpt-mini-latest",
            "openrouter/~x-ai/grok-latest",
            "openrouter/~deepseek/deepseek-v4-flash-latest",
            "openrouter/~moonshotai/kimi-latest",
            "openrouter/anthropic/claude-3.5-sonnet",
            "openrouter/anthropic/claude-3.5-haiku",
            "openrouter/anthropic/claude-3-opus",
            "openrouter/openai/gpt-4o",
            "openrouter/openai/gpt-4o-mini",
            "openrouter/openai/o1",
            "openrouter/openai/o3-mini",
            "openrouter/x-ai/grok-4.5",
            "openrouter/meta-llama/llama-3.3-70b-instruct",
            "openrouter/mistralai/mistral-large",
            "openrouter/deepseek/deepseek-chat",
            "openrouter/deepseek/deepseek-r1",
            "openrouter/qwen/qwen-2.5-coder-32b-instruct",
            "openrouter/qwen/qwen3-coder",
            "openrouter/nvidia/nemotron-3-ultra-550b-a55b",
            "openrouter/anthropic/claude-opus-4",
            "openrouter/anthropic/claude-sonnet-4"
        ],
        multilineNewline: Data([0x0A]),
        resume: .discoverable(
            resume: .separateTokens("--session"),
            placement: .appendFlags
        ),
        accessibilityIDPrefix: "Settings.OpenCode"
    )

    public static let antigravity = AgentDescriptor(
        kind: .antigravity,
        displayName: "Antigravity",
        binaryName: "agy",
        settingsKey: "antigravity",
        modelFlag: .separateTokens("--model"),
        effortFlag: .flag(.separateTokens("--effort")),
        promptFlag: .separateTokens("--prompt-interactive"),
        effortLevels: [.low, .medium, .high],
        effortLabels: [:],
        fallbackModels: [
            "gemini-3.7-flash-high",
            "gemini-3.7-flash-medium",
            "gemini-3.7-flash-low",
            "gemini-3.6-flash-high",
            "gemini-3.6-flash-medium",
            "gemini-3.6-flash-low",
            "gemini-3.5-flash-high",
            "gemini-3.5-flash-medium",
            "gemini-3.5-flash-low",
            "gemini-3.1-pro-high",
            "gemini-3.1-pro-low",
            "claude-sonnet-4-6",
            "claude-opus-4-6-thinking",
            "gpt-oss-120b-medium",
        ],
        multilineNewline: Data([0x0A]),
        resume: .discoverable(
            resume: .separateTokens("--conversation"),
            placement: .appendFlags
        ),
        accessibilityIDPrefix: "Settings.Antigravity"
    )
}
