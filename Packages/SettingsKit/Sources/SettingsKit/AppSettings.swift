import Foundation

/// Explicit per-agent binary path overrides. Kept as plain strings (not
/// keyed by SessionKit's `AgentKind`) so SettingsKit stays standalone —
/// AgentKit maps between the two where both are in scope.
public struct AgentPathOverrides: Codable, Equatable, Sendable {
    public var claudeCodePath: String
    public var codexCLIPath: String
    public var geminiCLIPath: String

    public init(claudeCodePath: String = "", codexCLIPath: String = "", geminiCLIPath: String = "") {
        self.claudeCodePath = claudeCodePath
        self.codexCLIPath = codexCLIPath
        self.geminiCLIPath = geminiCLIPath
    }
}

/// Arguments are stored as an array so they are passed directly to
/// `Process` without invoking a shell or reinterpreting user input.
public struct AgentArgumentOverrides: Codable, Equatable, Sendable {
    public var claudeCodeArguments: [String]
    public var codexCLIArguments: [String]
    public var geminiCLIArguments: [String]

    public init(
        claudeCodeArguments: [String] = [],
        codexCLIArguments: [String] = [],
        geminiCLIArguments: [String] = []
    ) {
        self.claudeCodeArguments = claudeCodeArguments
        self.codexCLIArguments = codexCLIArguments
        self.geminiCLIArguments = geminiCLIArguments
    }
}

public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

public struct SessionDefaults: Codable, Equatable, Sendable {
    public var defaultAgentRawValue: String
    public var createWorktreeByDefault: Bool

    public init(defaultAgentRawValue: String = "claudeCode", createWorktreeByDefault: Bool = true) {
        self.defaultAgentRawValue = defaultAgentRawValue
        self.createWorktreeByDefault = createWorktreeByDefault
    }
}

public struct TerminalPreferences: Codable, Equatable, Sendable {
    public var fontSize: Double
    public var optionActsAsMeta: Bool
    public var naturalTextSelection: Bool
    public var scrollSpeed: Double

    public init(
        fontSize: Double = 14,
        optionActsAsMeta: Bool = true,
        naturalTextSelection: Bool = true,
        scrollSpeed: Double = 1
    ) {
        self.fontSize = fontSize
        self.optionActsAsMeta = optionActsAsMeta
        self.naturalTextSelection = naturalTextSelection
        self.scrollSpeed = scrollSpeed
    }
}

public struct NotificationPreferences: Codable, Equatable, Sendable {
    public var waitingForInputEnabled: Bool
    public var finishedEnabled: Bool
    public var playsSound: Bool

    public init(
        waitingForInputEnabled: Bool = true,
        finishedEnabled: Bool = true,
        playsSound: Bool = true
    ) {
        self.waitingForInputEnabled = waitingForInputEnabled
        self.finishedEnabled = finishedEnabled
        self.playsSound = playsSound
    }
}

public struct GitPreferences: Codable, Equatable, Sendable {
    public var deleteBranchWithWorktree: Bool
    public var fetchBeforeCreatingWorktree: Bool

    public init(deleteBranchWithWorktree: Bool = true, fetchBeforeCreatingWorktree: Bool = false) {
        self.deleteBranchWithWorktree = deleteBranchWithWorktree
        self.fetchBeforeCreatingWorktree = fetchBeforeCreatingWorktree
    }
}

public struct InterfacePreferences: Codable, Equatable, Sendable {
    public var interfaceScale: Double
    public var density: String
    public var reduceDecorativeMotion: Bool

    public init(interfaceScale: Double = 1, density: String = "comfortable", reduceDecorativeMotion: Bool = false) {
        self.interfaceScale = interfaceScale
        self.density = density
        self.reduceDecorativeMotion = reduceDecorativeMotion
    }
}

public struct WorkspacePreferences: Codable, Equatable, Sendable {
    public var selectedSessionID: String?
    public var viewMode: String
    public var detailPanel: String
    public var gridMinimumTileWidth: Double

    public init(
        selectedSessionID: String? = nil,
        viewMode: String = "single",
        detailPanel: String = "terminal",
        gridMinimumTileWidth: Double = 420
    ) {
        self.selectedSessionID = selectedSessionID
        self.viewMode = viewMode
        self.detailPanel = detailPanel
        self.gridMinimumTileWidth = gridMinimumTileWidth
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var agentPaths: AgentPathOverrides
    public var agentArguments: AgentArgumentOverrides
    public var worktreeBaseDirectory: String
    public var appearance: AppearanceMode
    public var workspace: WorkspacePreferences
    public var sessionDefaults: SessionDefaults
    public var terminal: TerminalPreferences
    public var notifications: NotificationPreferences
    public var git: GitPreferences
    public var interface: InterfacePreferences

    public init(
        agentPaths: AgentPathOverrides = AgentPathOverrides(),
        agentArguments: AgentArgumentOverrides = AgentArgumentOverrides(),
        worktreeBaseDirectory: String = "",
        appearance: AppearanceMode = .system,
        workspace: WorkspacePreferences = WorkspacePreferences(),
        sessionDefaults: SessionDefaults = SessionDefaults(),
        terminal: TerminalPreferences = TerminalPreferences(),
        notifications: NotificationPreferences = NotificationPreferences(),
        git: GitPreferences = GitPreferences(),
        interface: InterfacePreferences = InterfacePreferences()
    ) {
        self.agentPaths = agentPaths
        self.agentArguments = agentArguments
        self.worktreeBaseDirectory = worktreeBaseDirectory
        self.appearance = appearance
        self.workspace = workspace
        self.sessionDefaults = sessionDefaults
        self.terminal = terminal
        self.notifications = notifications
        self.git = git
        self.interface = interface
    }

    private enum CodingKeys: String, CodingKey {
        case agentPaths
        case agentArguments
        case worktreeBaseDirectory
        case appearance
        case workspace
        case sessionDefaults
        case terminal
        case notifications
        case git
        case interface
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentPaths = try container.decodeIfPresent(AgentPathOverrides.self, forKey: .agentPaths) ?? AgentPathOverrides()
        agentArguments = try container.decodeIfPresent(AgentArgumentOverrides.self, forKey: .agentArguments) ?? AgentArgumentOverrides()
        worktreeBaseDirectory = try container.decodeIfPresent(String.self, forKey: .worktreeBaseDirectory) ?? ""
        appearance = try container.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? .system
        workspace = try container.decodeIfPresent(WorkspacePreferences.self, forKey: .workspace) ?? WorkspacePreferences()
        sessionDefaults = try container.decodeIfPresent(SessionDefaults.self, forKey: .sessionDefaults) ?? SessionDefaults()
        terminal = try container.decodeIfPresent(TerminalPreferences.self, forKey: .terminal) ?? TerminalPreferences()
        notifications = try container.decodeIfPresent(NotificationPreferences.self, forKey: .notifications) ?? NotificationPreferences()
        git = try container.decodeIfPresent(GitPreferences.self, forKey: .git) ?? GitPreferences()
        interface = try container.decodeIfPresent(InterfacePreferences.self, forKey: .interface) ?? InterfacePreferences()
    }
}
