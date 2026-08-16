import Foundation

/// Explicit per-agent binary path overrides. Kept as plain strings (not
/// keyed by SessionKit's `AgentKind`) so SettingsKit stays standalone —
/// AgentKit maps between the two where both are in scope.
public struct AgentPathOverrides: Codable, Equatable, Sendable {
    public var claudeCodePath: String
    public var codexCLIPath: String
    public var openCodePath: String

    public init(claudeCodePath: String = "", codexCLIPath: String = "", openCodePath: String = "") {
        self.claudeCodePath = claudeCodePath
        self.codexCLIPath = codexCLIPath
        self.openCodePath = openCodePath
    }

    private enum CodingKeys: String, CodingKey {
        case claudeCodePath
        case codexCLIPath
        case openCodePath
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        claudeCodePath = try container.decodeIfPresent(String.self, forKey: .claudeCodePath) ?? ""
        codexCLIPath = try container.decodeIfPresent(String.self, forKey: .codexCLIPath) ?? ""
        openCodePath = try container.decodeIfPresent(String.self, forKey: .openCodePath) ?? ""
    }
}

/// Arguments are stored as an array so they are passed directly to
/// `Process` without invoking a shell or reinterpreting user input.
public struct AgentArgumentOverrides: Codable, Equatable, Sendable {
    public var claudeCodeArguments: [String]
    public var codexCLIArguments: [String]
    public var openCodeArguments: [String]

    public init(
        claudeCodeArguments: [String] = [],
        codexCLIArguments: [String] = [],
        openCodeArguments: [String] = []
    ) {
        self.claudeCodeArguments = claudeCodeArguments
        self.codexCLIArguments = codexCLIArguments
        self.openCodeArguments = openCodeArguments
    }

    private enum CodingKeys: String, CodingKey {
        case claudeCodeArguments
        case codexCLIArguments
        case openCodeArguments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        claudeCodeArguments = try container.decodeIfPresent([String].self, forKey: .claudeCodeArguments) ?? []
        codexCLIArguments = try container.decodeIfPresent([String].self, forKey: .codexCLIArguments) ?? []
        openCodeArguments = try container.decodeIfPresent([String].self, forKey: .openCodeArguments) ?? []
    }
}

public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

/// The OpenCode plan the user subscribes to. Determines which provider's
/// models are listed when creating a session: AgentKit enumerates them with
/// `opencode models <providerID>`. `.none` keeps the built-in static list.
public enum OpenCodeSubscription: String, Codable, CaseIterable, Sendable, Identifiable {
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

    /// The provider slug passed to `opencode models <provider>`, or nil when
    /// no subscription is configured and model discovery stays static.
    public var providerID: String? {
        switch self {
        case .none: nil
        case .zen: "opencode"
        case .go: "opencode-go"
        }
    }
}

public struct SessionDefaults: Codable, Equatable, Sendable {
    public var createWorktreeByDefault: Bool
    public var defaultAgentRawValue: Int = 0

    public init(createWorktreeByDefault: Bool = true, defaultAgentRawValue: Int = 0) {
        self.createWorktreeByDefault = createWorktreeByDefault
        self.defaultAgentRawValue = defaultAgentRawValue
    }
}

public struct TerminalPreferences: Codable, Equatable, Sendable {
    public var fontSize: Double
    public var optionActsAsMeta: Bool
    public var naturalTextSelection: Bool
    public var scrollSpeed: Double
    public var gpuRendering: Bool

    public init(
        fontSize: Double = 14,
        optionActsAsMeta: Bool = true,
        naturalTextSelection: Bool = true,
        scrollSpeed: Double = 1,
        gpuRendering: Bool = false
    ) {
        self.fontSize = fontSize
        self.optionActsAsMeta = optionActsAsMeta
        self.naturalTextSelection = naturalTextSelection
        self.scrollSpeed = scrollSpeed
        self.gpuRendering = gpuRendering
    }

    private enum CodingKeys: String, CodingKey {
        case fontSize, optionActsAsMeta, naturalTextSelection, scrollSpeed, gpuRendering
    }

    // Hand-written rather than synthesized: `SettingsStoring` decodes the
    // whole `AppSettings` tree with `try?`, so a throwing `Decodable` for a
    // key added after a user's settings file was already written (like
    // `gpuRendering`) would silently reset every setting, not just this
    // struct's. `decodeIfPresent` with an explicit default keeps old files
    // decoding successfully.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 14
        optionActsAsMeta = try container.decodeIfPresent(Bool.self, forKey: .optionActsAsMeta) ?? true
        naturalTextSelection = try container.decodeIfPresent(Bool.self, forKey: .naturalTextSelection) ?? true
        scrollSpeed = try container.decodeIfPresent(Double.self, forKey: .scrollSpeed) ?? 1
        gpuRendering = try container.decodeIfPresent(Bool.self, forKey: .gpuRendering) ?? false
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
    public var openCodeSubscription: OpenCodeSubscription
    public var worktreeBaseDirectory: String
    public var appearance: AppearanceMode
    public var workspace: WorkspacePreferences
    public var sessionDefaults: SessionDefaults
    public var terminal: TerminalPreferences
    public var notifications: NotificationPreferences
    public var git: GitPreferences

    public init(
        agentPaths: AgentPathOverrides = AgentPathOverrides(),
        agentArguments: AgentArgumentOverrides = AgentArgumentOverrides(),
        openCodeSubscription: OpenCodeSubscription = .none,
        worktreeBaseDirectory: String = "",
        appearance: AppearanceMode = .system,
        workspace: WorkspacePreferences = WorkspacePreferences(),
        sessionDefaults: SessionDefaults = SessionDefaults(),
        terminal: TerminalPreferences = TerminalPreferences(),
        notifications: NotificationPreferences = NotificationPreferences(),
        git: GitPreferences = GitPreferences()
    ) {
        self.agentPaths = agentPaths
        self.agentArguments = agentArguments
        self.openCodeSubscription = openCodeSubscription
        self.worktreeBaseDirectory = worktreeBaseDirectory
        self.appearance = appearance
        self.workspace = workspace
        self.sessionDefaults = sessionDefaults
        self.terminal = terminal
        self.notifications = notifications
        self.git = git
    }

    private enum CodingKeys: String, CodingKey {
        case agentPaths
        case agentArguments
        case openCodeSubscription
        case worktreeBaseDirectory
        case appearance
        case workspace
        case sessionDefaults
        case terminal
        case notifications
        case git
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentPaths = try container.decodeIfPresent(AgentPathOverrides.self, forKey: .agentPaths) ?? AgentPathOverrides()
        agentArguments = try container.decodeIfPresent(AgentArgumentOverrides.self, forKey: .agentArguments) ?? AgentArgumentOverrides()
        openCodeSubscription = try container.decodeIfPresent(OpenCodeSubscription.self, forKey: .openCodeSubscription) ?? .none
        worktreeBaseDirectory = try container.decodeIfPresent(String.self, forKey: .worktreeBaseDirectory) ?? ""
        appearance = try container.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? .system
        workspace = try container.decodeIfPresent(WorkspacePreferences.self, forKey: .workspace) ?? WorkspacePreferences()
        sessionDefaults = try container.decodeIfPresent(SessionDefaults.self, forKey: .sessionDefaults) ?? SessionDefaults()
        terminal = try container.decodeIfPresent(TerminalPreferences.self, forKey: .terminal) ?? TerminalPreferences()
        notifications = try container.decodeIfPresent(NotificationPreferences.self, forKey: .notifications) ?? NotificationPreferences()
        git = try container.decodeIfPresent(GitPreferences.self, forKey: .git) ?? GitPreferences()
    }
}
