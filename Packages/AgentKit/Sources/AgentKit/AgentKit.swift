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
        resumeIntent: ResumeIntent = .none,
        settings: AppSettings = AppSettings(),
        baseEnvironment: [String: String] = [:]
    ) -> AgentLaunchPlan {
        launchPlan(
            goal: goal,
            model: model,
            effort: effort,
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

        let fullArguments = leadingSubcommands + arguments

        return AgentLaunchPlan(
            binaryName: descriptor.binaryName,
            configuredPath: settings.agentOverrides.paths[descriptor.settingsKey] ?? "",
            arguments: fullArguments,
            environment: environment,
            initialInput: input
        )
    }
}

public struct AgentProviderRegistry: Sendable {
    public init() {}

    public func provider(for kind: AgentKind) -> any AgentProviding {
        CLIAgentProvider(kind: kind)
    }
}
