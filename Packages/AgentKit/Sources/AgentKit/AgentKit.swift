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

public enum ResumeIntent: Equatable, Sendable {
    case freshWithAssignedIdentity(String)  // Claude, first launch
    case resume(String)                     // any agent, known id
    case none                               // discoverable agent, first launch
}

public protocol AgentProviding: Sendable {
    var kind: AgentKind { get }
    var binaryName: String { get }
    func launchPlan(
        goal: String?,
        model: String?,
        effort: AgentEffort?,
        mode: SessionMode,
        resumeIntent: ResumeIntent,
        settings: AppSettings,
        baseEnvironment: [String: String]
    ) -> AgentLaunchPlan
}

extension AgentProviding {
    public func launchPlan(
        goal: String? = nil,
        model: String? = nil,
        effort: AgentEffort? = nil,
        mode: SessionMode = .act,
        resumeIntent: ResumeIntent = .none,
        settings: AppSettings = AppSettings(),
        baseEnvironment: [String: String] = [:]
    ) -> AgentLaunchPlan {
        launchPlan(
            goal: goal,
            model: model,
            effort: effort,
            mode: mode,
            resumeIntent: resumeIntent,
            settings: settings,
            baseEnvironment: baseEnvironment
        )
    }

    public func launchPlan(
        goal: String?,
        model: String?,
        effort: AgentEffort?,
        settings: AppSettings,
        baseEnvironment: [String: String]
    ) -> AgentLaunchPlan {
        launchPlan(
            goal: goal,
            model: model,
            effort: effort,
            mode: .act,
            resumeIntent: .none,
            settings: settings,
            baseEnvironment: baseEnvironment
        )
    }

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
            mode: .act,
            resumeIntent: .none,
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
            mode: .act,
            resumeIntent: .none,
            settings: settings,
            baseEnvironment: baseEnvironment
        )
    }
}

public struct CLIAgentProvider: AgentProviding {
    public let kind: AgentKind
    public var binaryName: String { descriptor.binaryName }
    public var descriptor: AgentDescriptor { AgentCatalog.descriptor(for: kind) }

    public init(kind: AgentKind, binaryName: String? = nil) {
        self.kind = kind
    }

    public func launchPlan(
        goal: String?,
        model: String?,
        effort: AgentEffort?,
        mode: SessionMode,
        resumeIntent: ResumeIntent,
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

        var arguments = settings.agentOverrides.arguments[descriptor.settingsKey] ?? []
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedModel.isEmpty, let modelFlag = descriptor.modelFlag {
            arguments += modelFlag.arguments(for: trimmedModel)
        }
        // A level the CLI doesn't accept is dropped rather than passed
        // through: Claude Code warns and silently falls back to its default,
        // and Codex rejects the run outright. The picker already narrows the
        // choice per agent and model — this is the last line of defence for a
        // level carried over from a session created against another agent.
        if let effort, descriptor.effortLevels.contains(effort), let effortFlag = descriptor.effortFlag {
            arguments += effortFlag.arguments(for: effort)
        }

        // Planning-mode flags vary by CLI.
        // Codex has no startup flag — planning mode is delivered via initialInput below.
        if mode == .plan {
            switch kind {
            case .claudeCode:
                arguments += ["--permission-mode", "plan"]
            case .antigravity:
                arguments += ["--mode", "plan"]
            case .openCode:
                arguments += ["--mode", "plan"]
            case .codexCLI:
                break
            }
        }

        var leadingSubcommands: [String] = []
        switch resumeIntent {
        case .freshWithAssignedIdentity(let id):
            if case .assignable(let assignSpec, _, let placement) = descriptor.resume {
                let flags = assignSpec.arguments(for: id)
                switch placement {
                case .appendFlags:
                    arguments += flags
                case .leadingSubcommand(let subcommand):
                    leadingSubcommands = [subcommand] + flags
                }
            }
        case .resume(let id):
            switch descriptor.resume {
            case .assignable(_, let resumeSpec, let placement),
                 .discoverable(let resumeSpec, let placement):
                let flags = resumeSpec.arguments(for: id)
                switch placement {
                case .appendFlags:
                    arguments += flags
                case .leadingSubcommand(let subcommand):
                    leadingSubcommands = [subcommand] + flags
                }
            case .unsupported:
                break
            }
        case .none:
            break
        }

        // Codex plan mode: withhold the goal from argv and deliver it via
        // initialInput as "/plan <goal>" so Codex's TUI processes the slash
        // command. Other agents receive the goal normally via their promptFlag.
        let codexPlanInitialInput: Data?
        if mode == .plan, kind == .codexCLI, !trimmedGoal.isEmpty,
           case .none = resumeIntent {
            codexPlanInitialInput = "/plan \(trimmedGoal)\n"
                .data(using: .utf8)
        } else {
            codexPlanInitialInput = nil
        }

        let skipPromptFlag = codexPlanInitialInput != nil
        if !skipPromptFlag {
            if !trimmedGoal.isEmpty, case .resume = resumeIntent {
                // Resumed sessions do not receive an initial prompt argument
            } else if !trimmedGoal.isEmpty, let promptFlag = descriptor.promptFlag {
                arguments += promptFlag.arguments(for: trimmedGoal)
            }
        }

        let fullArguments = leadingSubcommands + arguments

        return AgentLaunchPlan(
            binaryName: descriptor.binaryName,
            configuredPath: settings.agentOverrides.paths[descriptor.settingsKey] ?? "",
            arguments: fullArguments,
            environment: environment,
            initialInput: codexPlanInitialInput
        )
    }
}

public struct AgentProviderRegistry: Sendable {
    public init() {}

    public func provider(for kind: AgentKind) -> any AgentProviding {
        CLIAgentProvider(kind: kind)
    }
}
