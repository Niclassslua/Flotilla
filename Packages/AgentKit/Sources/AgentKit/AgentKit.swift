import Foundation
import SessionKit
import SettingsKit
import ProcessKit

/// Everything needed to launch one supported CLI. This deliberately has no
/// credential fields: authentication remains entirely owned by each agent.
public struct AgentLaunchPlan: Equatable, Sendable {
    public var binaryName: String
    public var configuredPath: String
    public var arguments: [String]
    public var environment: [String: String]
    public var initialInput: Data?

    public init(
        binaryName: String,
        configuredPath: String,
        arguments: [String],
        environment: [String: String],
        initialInput: Data?
    ) {
        self.binaryName = binaryName
        self.configuredPath = configuredPath
        self.arguments = arguments
        self.environment = environment
        self.initialInput = initialInput
    }
}

public protocol AgentProviding: Sendable {
    var kind: AgentKind { get }
    var binaryName: String { get }
    func launchPlan(
        goal: String?,
        model: String?,
        effort: AgentEffort?,
        settings: AppSettings,
        baseEnvironment: [String: String]
    ) -> AgentLaunchPlan
}

extension AgentProviding {
    /// Convenience overload for callers that don't need to set effort.
    public func launchPlan(
        goal: String?,
        model: String?,
        settings: AppSettings,
        baseEnvironment: [String: String]
    ) -> AgentLaunchPlan {
        launchPlan(
            goal: goal,
            model: model,
            effort: nil,
            settings: settings,
            baseEnvironment: baseEnvironment
        )
    }

    /// Convenience overload for callers that don't need to pin a model.
    public func launchPlan(
        goal: String?,
        settings: AppSettings,
        baseEnvironment: [String: String]
    ) -> AgentLaunchPlan {
        launchPlan(
            goal: goal,
            model: nil,
            effort: nil,
            settings: settings,
            baseEnvironment: baseEnvironment
        )
    }
}

public struct CLIAgentProvider: AgentProviding {
    public let kind: AgentKind
    public let binaryName: String

    public init(kind: AgentKind, binaryName: String) {
        self.kind = kind
        self.binaryName = binaryName
    }

    public func launchPlan(
        goal: String?,
        model: String?,
        effort: AgentEffort?,
        settings: AppSettings,
        baseEnvironment: [String: String]
    ) -> AgentLaunchPlan {
        var environment = baseEnvironment
        // GUI-launched apps (Finder, or Xcode's debugger) get their
        // environment from launchd, not a shell — that's either no `TERM`
        // at all, or `TERM=dumb`. `dumb` is present-but-unusable the same
        // way `TmuxSessionWrapping` documents for its own outer client: a
        // plain `?? "..."` fallback only fires when the key is *absent*, so
        // a `dumb` inherited value survives here and reaches the agent CLI
        // directly, whose color-support detection sees `dumb` and disables
        // all color output — the terminal renders in black and white.
        if environment["TERM"] == nil || environment["TERM"] == "dumb" {
            environment["TERM"] = "xterm-256color"
        }
        environment["COLORTERM"] = environment["COLORTERM"] ?? "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["PATH"] = PATHExecutableLocator.augmentedPATH(
            pathEnvironment: environment["PATH"] ?? ""
        )

        let trimmedGoal = goal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Neither a trailing "\n" nor "\r" reliably submits in Claude
        // Code's or Codex's interactive composer when written directly to
        // the PTY like this — both real CLIs' TUIs appear to treat a bulk
        // write as paste-like content needing a separate, genuine keystroke
        // to confirm, so the goal is left typed-but-unsent until the user
        // manually presses Enter. `\r` is kept here as the conventional
        // choice for a literal Enter keystroke; it's not known to matter
        // either way. When tmux is available, `SessionProcessManager`
        // delivers the goal via `tmux send-keys` instead, which is
        // confirmed to actually submit — this raw write only remains as the
        // fallback for sessions launched without tmux.
        let input = trimmedGoal.isEmpty ? nil : Data("\(trimmedGoal)\r".utf8)

        var arguments = configuredArguments(in: settings.agentArguments)
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedModel.isEmpty {
            arguments += ["--model", trimmedModel]
        }
        if let effort {
            switch kind {
            case .claudeCode:
                arguments += ["--effort", effort.rawValue]
            case .codexCLI:
                arguments += ["--config", "model_reasoning_effort=\"\(effort.rawValue)\""]
            case .openCode:
                break
            }
        }

        return AgentLaunchPlan(
            binaryName: binaryName,
            configuredPath: configuredPath(in: settings.agentPaths),
            arguments: arguments,
            environment: environment,
            initialInput: input
        )
    }

    private func configuredPath(in paths: AgentPathOverrides) -> String {
        switch kind {
        case .claudeCode: paths.claudeCodePath
        case .codexCLI: paths.codexCLIPath
        case .openCode: paths.openCodePath
        }
    }

    private func configuredArguments(in arguments: AgentArgumentOverrides) -> [String] {
        switch kind {
        case .claudeCode: arguments.claudeCodeArguments
        case .codexCLI: arguments.codexCLIArguments
        case .openCode: arguments.openCodeArguments
        }
    }
}

public struct AgentProviderRegistry: Sendable {
    public init() {}

    public func provider(for kind: AgentKind) -> any AgentProviding {
        switch kind {
        case .claudeCode:
            CLIAgentProvider(kind: kind, binaryName: "claude")
        case .codexCLI:
            CLIAgentProvider(kind: kind, binaryName: "codex")
        case .openCode:
            CLIAgentProvider(kind: kind, binaryName: "opencode")
        }
    }
}
