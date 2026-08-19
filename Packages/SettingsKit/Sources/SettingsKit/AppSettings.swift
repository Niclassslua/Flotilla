import Foundation

/// Explicit per-agent binary path and argument overrides, keyed by the agent's
/// raw value string so SettingsKit stays independent of SessionKit.
public struct AgentOverrides: Codable, Equatable, Sendable {
    public var paths: [String: String]
    public var arguments: [String: [String]]

    public init(
        paths: [String: String] = [:],
        arguments: [String: [String]] = [:]
    ) {
        self.paths = paths
        self.arguments = arguments
    }

    private enum CodingKeys: String, CodingKey {
        case paths
        case arguments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paths = try container.decodeIfPresent([String: String].self, forKey: .paths) ?? [:]
        arguments = try container.decodeIfPresent([String: [String]].self, forKey: .arguments) ?? [:]
    }
}

/// Explicit per-agent binary path overrides (legacy DTO kept for migration and compatibility).
public struct AgentPathOverrides: Codable, Equatable, Sendable {
    public var claudeCodePath: String
    public var codexCLIPath: String
    public var openCodePath: String
    public var antigravityPath: String

    public init(
        claudeCodePath: String = "",
        codexCLIPath: String = "",
        openCodePath: String = "",
        antigravityPath: String = ""
    ) {
        self.claudeCodePath = claudeCodePath
        self.codexCLIPath = codexCLIPath
        self.openCodePath = openCodePath
        self.antigravityPath = antigravityPath
    }

    private enum CodingKeys: String, CodingKey {
        case claudeCodePath
        case codexCLIPath
        case openCodePath
        case antigravityPath
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        claudeCodePath = try container.decodeIfPresent(String.self, forKey: .claudeCodePath) ?? ""
        codexCLIPath = try container.decodeIfPresent(String.self, forKey: .codexCLIPath) ?? ""
        openCodePath = try container.decodeIfPresent(String.self, forKey: .openCodePath) ?? ""
        antigravityPath = try container.decodeIfPresent(String.self, forKey: .antigravityPath) ?? ""
    }
}

/// Legacy DTO kept for migration and compatibility.
public struct AgentArgumentOverrides: Codable, Equatable, Sendable {
    public var claudeCodeArguments: [String]
    public var codexCLIArguments: [String]
    public var openCodeArguments: [String]
    public var antigravityArguments: [String]

    public init(
        claudeCodeArguments: [String] = [],
        codexCLIArguments: [String] = [],
        openCodeArguments: [String] = [],
        antigravityArguments: [String] = []
    ) {
        self.claudeCodeArguments = claudeCodeArguments
        self.codexCLIArguments = codexCLIArguments
        self.openCodeArguments = openCodeArguments
        self.antigravityArguments = antigravityArguments
    }

    private enum CodingKeys: String, CodingKey {
        case claudeCodeArguments
        case codexCLIArguments
        case openCodeArguments
        case antigravityArguments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        claudeCodeArguments = try container.decodeIfPresent([String].self, forKey: .claudeCodeArguments) ?? []
        codexCLIArguments = try container.decodeIfPresent([String].self, forKey: .codexCLIArguments) ?? []
        openCodeArguments = try container.decodeIfPresent([String].self, forKey: .openCodeArguments) ?? []
        antigravityArguments = try container.decodeIfPresent([String].self, forKey: .antigravityArguments) ?? []
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
    public var defaultAgentRawValue: String = "claudeCode"

    public init(createWorktreeByDefault: Bool = true, defaultAgentRawValue: String = "claudeCode") {
        self.createWorktreeByDefault = createWorktreeByDefault
        self.defaultAgentRawValue = defaultAgentRawValue
    }

    private enum CodingKeys: String, CodingKey {
        case createWorktreeByDefault
        case defaultAgentRawValue
    }

    // Hand-written rather than synthesized: `SettingsStoring` decodes the
    // whole `AppSettings` tree with `try?`, so a throwing `Decodable` for a
    // key added after a user's settings file was already written would
    // silently reset every setting. `decodeIfPresent` with an explicit
    // default keeps old files decoding successfully.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        createWorktreeByDefault = try container.decodeIfPresent(Bool.self, forKey: .createWorktreeByDefault) ?? true
        if let stringValue = try? container.decode(String.self, forKey: .defaultAgentRawValue) {
            defaultAgentRawValue = stringValue
        } else if let intValue = try? container.decode(Int.self, forKey: .defaultAgentRawValue) {
            let legacyKinds = ["claudeCode", "codexCLI", "openCode", "antigravity"]
            if intValue >= 0 && intValue < legacyKinds.count {
                defaultAgentRawValue = legacyKinds[intValue]
            } else {
                defaultAgentRawValue = "claudeCode"
            }
        } else {
            defaultAgentRawValue = "claudeCode"
        }
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
    /// The grid's single layout knob: how wide a tile wants to be. The column
    /// count follows from it, so there is no separate column setting.
    public var gridMinimumTileWidth: Double
    public var gridSessionOrder: [String]
    /// Shows a text label under each sidebar rail icon (Overview/Sessions/
    /// Projects/New) instead of icon-only with a hover tooltip.
    public var sidebarRailLabels: Bool

    public init(
        selectedSessionID: String? = nil,
        viewMode: String = "single",
        detailPanel: String = "terminal",
        gridMinimumTileWidth: Double = 410,
        gridSessionOrder: [String] = [],
        sidebarRailLabels: Bool = false
    ) {
        self.selectedSessionID = selectedSessionID
        self.viewMode = viewMode
        self.detailPanel = detailPanel
        self.gridMinimumTileWidth = gridMinimumTileWidth
        self.gridSessionOrder = gridSessionOrder
        self.sidebarRailLabels = sidebarRailLabels
    }

    private enum CodingKeys: String, CodingKey {
        case selectedSessionID, viewMode, detailPanel, gridMinimumTileWidth, gridSessionOrder, sidebarRailLabels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedSessionID = try container.decodeIfPresent(String.self, forKey: .selectedSessionID)
        viewMode = try container.decodeIfPresent(String.self, forKey: .viewMode) ?? "single"
        detailPanel = try container.decodeIfPresent(String.self, forKey: .detailPanel) ?? "terminal"
        gridMinimumTileWidth = try container.decodeIfPresent(Double.self, forKey: .gridMinimumTileWidth) ?? 410
        gridSessionOrder = try container.decodeIfPresent([String].self, forKey: .gridSessionOrder) ?? []
        sidebarRailLabels = try container.decodeIfPresent(Bool.self, forKey: .sidebarRailLabels) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(selectedSessionID, forKey: .selectedSessionID)
        try container.encodeIfPresent(viewMode, forKey: .viewMode)
        try container.encodeIfPresent(detailPanel, forKey: .detailPanel)
        try container.encodeIfPresent(gridMinimumTileWidth, forKey: .gridMinimumTileWidth)
        try container.encodeIfPresent(gridSessionOrder, forKey: .gridSessionOrder)
        try container.encodeIfPresent(sidebarRailLabels, forKey: .sidebarRailLabels)
    }

}

public struct AppSettings: Codable, Equatable, Sendable {
    public var agentOverrides: AgentOverrides
    public var openCodeSubscription: OpenCodeSubscription
    public var worktreeBaseDirectory: String
    public var appearance: AppearanceMode
    public var workspace: WorkspacePreferences
    public var sessionDefaults: SessionDefaults
    public var terminal: TerminalPreferences
    public var notifications: NotificationPreferences
    public var git: GitPreferences

    public var agentPaths: AgentPathOverrides {
        get {
            AgentPathOverrides(
                claudeCodePath: agentOverrides.paths["claudeCode"] ?? "",
                codexCLIPath: agentOverrides.paths["codexCLI"] ?? "",
                openCodePath: agentOverrides.paths["openCode"] ?? "",
                antigravityPath: agentOverrides.paths["antigravity"] ?? ""
            )
        }
        set {
            if newValue.claudeCodePath.isEmpty { agentOverrides.paths.removeValue(forKey: "claudeCode") } else { agentOverrides.paths["claudeCode"] = newValue.claudeCodePath }
            if newValue.codexCLIPath.isEmpty { agentOverrides.paths.removeValue(forKey: "codexCLI") } else { agentOverrides.paths["codexCLI"] = newValue.codexCLIPath }
            if newValue.openCodePath.isEmpty { agentOverrides.paths.removeValue(forKey: "openCode") } else { agentOverrides.paths["openCode"] = newValue.openCodePath }
            if newValue.antigravityPath.isEmpty { agentOverrides.paths.removeValue(forKey: "antigravity") } else { agentOverrides.paths["antigravity"] = newValue.antigravityPath }
        }
    }

    public var agentArguments: AgentArgumentOverrides {
        get {
            AgentArgumentOverrides(
                claudeCodeArguments: agentOverrides.arguments["claudeCode"] ?? [],
                codexCLIArguments: agentOverrides.arguments["codexCLI"] ?? [],
                openCodeArguments: agentOverrides.arguments["openCode"] ?? [],
                antigravityArguments: agentOverrides.arguments["antigravity"] ?? []
            )
        }
        set {
            if newValue.claudeCodeArguments.isEmpty { agentOverrides.arguments.removeValue(forKey: "claudeCode") } else { agentOverrides.arguments["claudeCode"] = newValue.claudeCodeArguments }
            if newValue.codexCLIArguments.isEmpty { agentOverrides.arguments.removeValue(forKey: "codexCLI") } else { agentOverrides.arguments["codexCLI"] = newValue.codexCLIArguments }
            if newValue.openCodeArguments.isEmpty { agentOverrides.arguments.removeValue(forKey: "openCode") } else { agentOverrides.arguments["openCode"] = newValue.openCodeArguments }
            if newValue.antigravityArguments.isEmpty { agentOverrides.arguments.removeValue(forKey: "antigravity") } else { agentOverrides.arguments["antigravity"] = newValue.antigravityArguments }
        }
    }

    public init(
        agentOverrides: AgentOverrides = AgentOverrides(),
        openCodeSubscription: OpenCodeSubscription = .none,
        worktreeBaseDirectory: String = "",
        appearance: AppearanceMode = .system,
        workspace: WorkspacePreferences = WorkspacePreferences(),
        sessionDefaults: SessionDefaults = SessionDefaults(),
        terminal: TerminalPreferences = TerminalPreferences(),
        notifications: NotificationPreferences = NotificationPreferences(),
        git: GitPreferences = GitPreferences()
    ) {
        self.agentOverrides = agentOverrides
        self.openCodeSubscription = openCodeSubscription
        self.worktreeBaseDirectory = worktreeBaseDirectory
        self.appearance = appearance
        self.workspace = workspace
        self.sessionDefaults = sessionDefaults
        self.terminal = terminal
        self.notifications = notifications
        self.git = git
    }

    public init(
        agentPaths: AgentPathOverrides,
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
        var paths: [String: String] = [:]
        if !agentPaths.claudeCodePath.isEmpty { paths["claudeCode"] = agentPaths.claudeCodePath }
        if !agentPaths.codexCLIPath.isEmpty { paths["codexCLI"] = agentPaths.codexCLIPath }
        if !agentPaths.openCodePath.isEmpty { paths["openCode"] = agentPaths.openCodePath }
        if !agentPaths.antigravityPath.isEmpty { paths["antigravity"] = agentPaths.antigravityPath }

        var arguments: [String: [String]] = [:]
        if !agentArguments.claudeCodeArguments.isEmpty { arguments["claudeCode"] = agentArguments.claudeCodeArguments }
        if !agentArguments.codexCLIArguments.isEmpty { arguments["codexCLI"] = agentArguments.codexCLIArguments }
        if !agentArguments.openCodeArguments.isEmpty { arguments["openCode"] = agentArguments.openCodeArguments }
        if !agentArguments.antigravityArguments.isEmpty { arguments["antigravity"] = agentArguments.antigravityArguments }

        self.agentOverrides = AgentOverrides(paths: paths, arguments: arguments)
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
        case agentOverrides
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
        if let overrides = try container.decodeIfPresent(AgentOverrides.self, forKey: .agentOverrides) {
            self.agentOverrides = overrides
        } else {
            var paths: [String: String] = [:]
            var arguments: [String: [String]] = [:]
            if let legacyPaths = try container.decodeIfPresent(AgentPathOverrides.self, forKey: .agentPaths) {
                if !legacyPaths.claudeCodePath.isEmpty { paths["claudeCode"] = legacyPaths.claudeCodePath }
                if !legacyPaths.codexCLIPath.isEmpty { paths["codexCLI"] = legacyPaths.codexCLIPath }
                if !legacyPaths.openCodePath.isEmpty { paths["openCode"] = legacyPaths.openCodePath }
                if !legacyPaths.antigravityPath.isEmpty { paths["antigravity"] = legacyPaths.antigravityPath }
            }
            if let legacyArgs = try container.decodeIfPresent(AgentArgumentOverrides.self, forKey: .agentArguments) {
                if !legacyArgs.claudeCodeArguments.isEmpty { arguments["claudeCode"] = legacyArgs.claudeCodeArguments }
                if !legacyArgs.codexCLIArguments.isEmpty { arguments["codexCLI"] = legacyArgs.codexCLIArguments }
                if !legacyArgs.openCodeArguments.isEmpty { arguments["openCode"] = legacyArgs.openCodeArguments }
                if !legacyArgs.antigravityArguments.isEmpty { arguments["antigravity"] = legacyArgs.antigravityArguments }
            }
            self.agentOverrides = AgentOverrides(paths: paths, arguments: arguments)
        }
        openCodeSubscription = try container.decodeIfPresent(OpenCodeSubscription.self, forKey: .openCodeSubscription) ?? .none
        worktreeBaseDirectory = try container.decodeIfPresent(String.self, forKey: .worktreeBaseDirectory) ?? ""
        appearance = try container.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? .system
        workspace = try container.decodeIfPresent(WorkspacePreferences.self, forKey: .workspace) ?? WorkspacePreferences()
        sessionDefaults = try container.decodeIfPresent(SessionDefaults.self, forKey: .sessionDefaults) ?? SessionDefaults()
        terminal = try container.decodeIfPresent(TerminalPreferences.self, forKey: .terminal) ?? TerminalPreferences()
        notifications = try container.decodeIfPresent(NotificationPreferences.self, forKey: .notifications) ?? NotificationPreferences()
        git = try container.decodeIfPresent(GitPreferences.self, forKey: .git) ?? GitPreferences()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(agentOverrides, forKey: .agentOverrides)
        try container.encode(openCodeSubscription, forKey: .openCodeSubscription)
        try container.encode(worktreeBaseDirectory, forKey: .worktreeBaseDirectory)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(workspace, forKey: .workspace)
        try container.encode(sessionDefaults, forKey: .sessionDefaults)
        try container.encode(terminal, forKey: .terminal)
        try container.encode(notifications, forKey: .notifications)
        try container.encode(git, forKey: .git)
    }
}
