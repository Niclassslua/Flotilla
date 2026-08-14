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
        settings: AppSettings,
        baseEnvironment: [String: String]
    ) -> AgentLaunchPlan
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
        settings: AppSettings,
        baseEnvironment: [String: String]
    ) -> AgentLaunchPlan {
        var environment = baseEnvironment
        environment["TERM"] = environment["TERM"] ?? "xterm-256color"
        environment["COLORTERM"] = environment["COLORTERM"] ?? "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["PATH"] = PATHExecutableLocator.augmentedPATH(
            pathEnvironment: environment["PATH"] ?? ""
        )

        let trimmedGoal = goal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let input = trimmedGoal.isEmpty ? nil : Data("\(trimmedGoal)\n".utf8)
        return AgentLaunchPlan(
            binaryName: binaryName,
            configuredPath: configuredPath(in: settings.agentPaths),
            arguments: configuredArguments(in: settings.agentArguments),
            environment: environment,
            initialInput: input
        )
    }

    private func configuredPath(in paths: AgentPathOverrides) -> String {
        switch kind {
        case .claudeCode: paths.claudeCodePath
        case .codexCLI: paths.codexCLIPath
        case .geminiCLI: paths.geminiCLIPath
        }
    }

    private func configuredArguments(in arguments: AgentArgumentOverrides) -> [String] {
        switch kind {
        case .claudeCode: arguments.claudeCodeArguments
        case .codexCLI: arguments.codexCLIArguments
        case .geminiCLI: arguments.geminiCLIArguments
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
        case .geminiCLI:
            CLIAgentProvider(kind: kind, binaryName: "gemini")
        }
    }
}
