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
    public var cursorAgentPath: String

    public init(
        claudeCodePath: String = "",
        codexCLIPath: String = "",
        openCodePath: String = "",
        antigravityPath: String = "",
        cursorAgentPath: String = ""
    ) {
        self.claudeCodePath = claudeCodePath
        self.codexCLIPath = codexCLIPath
        self.openCodePath = openCodePath
        self.antigravityPath = antigravityPath
        self.cursorAgentPath = cursorAgentPath
    }

    private enum CodingKeys: String, CodingKey {
        case claudeCodePath
        case codexCLIPath
        case openCodePath
        case antigravityPath
        case cursorAgentPath
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        claudeCodePath = try container.decodeIfPresent(String.self, forKey: .claudeCodePath) ?? ""
        codexCLIPath = try container.decodeIfPresent(String.self, forKey: .codexCLIPath) ?? ""
        openCodePath = try container.decodeIfPresent(String.self, forKey: .openCodePath) ?? ""
        antigravityPath = try container.decodeIfPresent(String.self, forKey: .antigravityPath) ?? ""
        cursorAgentPath = try container.decodeIfPresent(String.self, forKey: .cursorAgentPath) ?? ""
    }
}

/// Legacy DTO kept for migration and compatibility.
public struct AgentArgumentOverrides: Codable, Equatable, Sendable {
    public var claudeCodeArguments: [String]
    public var codexCLIArguments: [String]
    public var openCodeArguments: [String]
    public var antigravityArguments: [String]
    public var cursorAgentArguments: [String]

    public init(
        claudeCodeArguments: [String] = [],
        codexCLIArguments: [String] = [],
        openCodeArguments: [String] = [],
        antigravityArguments: [String] = [],
        cursorAgentArguments: [String] = []
    ) {
        self.claudeCodeArguments = claudeCodeArguments
        self.codexCLIArguments = codexCLIArguments
        self.openCodeArguments = openCodeArguments
        self.antigravityArguments = antigravityArguments
        self.cursorAgentArguments = cursorAgentArguments
    }

    private enum CodingKeys: String, CodingKey {
        case claudeCodeArguments
        case codexCLIArguments
        case openCodeArguments
        case antigravityArguments
        case cursorAgentArguments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        claudeCodeArguments = try container.decodeIfPresent([String].self, forKey: .claudeCodeArguments) ?? []
        codexCLIArguments = try container.decodeIfPresent([String].self, forKey: .codexCLIArguments) ?? []
        openCodeArguments = try container.decodeIfPresent([String].self, forKey: .openCodeArguments) ?? []
        antigravityArguments = try container.decodeIfPresent([String].self, forKey: .antigravityArguments) ?? []
        cursorAgentArguments = try container.decodeIfPresent([String].self, forKey: .cursorAgentArguments) ?? []
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

/// Where a session's title, branch name, and worktree path all come from.
///
/// These three used to be two independently-configured settings (title vs.
/// worktree/branch). Splitting them let a session end up with, say, an
/// Apple-Intelligence title but an agent-managed worktree — Flotilla would
/// resolve the title synchronously before spawning the agent, then throw it
/// away and have the agent invent an unrelated slug for the worktree it
/// created itself. One setting drives all three together so that never
/// happens: `.appleIntelligence`/`.promptDerived` always resolve a name
/// synchronously and let Flotilla create the worktree from it before the
/// agent is spawned; only `.agentManaged` defers naming (of the title, and
/// the worktree/branch when one is being created) to the agent itself.
public enum SessionNamingSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case appleIntelligence
    case promptDerived
    case agentManaged

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence"
        case .promptDerived: "Derived from prompt"
        case .agentManaged: "Chosen by the agent"
        }
    }
}

/// Where Flotilla records which agent session made a commit.
///
/// `local` keeps the record in Flotilla's own database and never writes into
/// the repository. `shared` commits a small marker with each agent commit, so
/// the attribution travels with the history to every clone.
public enum CommitAttributionMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case off
    case local
    case shared

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .local: "On this Mac"
        case .shared: "Shared in the repository"
        }
    }
}

/// Pre-selected worktree choice when confirming a session delete.
///
/// The delete sheet still asks every time; this only picks which option is
/// selected when it opens. The main checkout is never deleted either way.
public enum WorktreeOnSessionDelete: String, Codable, CaseIterable, Sendable, Identifiable {
    case keep
    case remove

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .keep: "Keep worktree"
        case .remove: "Remove worktree"
        }
    }

    /// Value handed to `deleteSession(deleteWorktree:)`.
    public var deletesWorktree: Bool {
        self == .remove
    }
}

public struct SessionDefaults: Codable, Equatable, Sendable {
    public var createWorktreeByDefault: Bool
    public var defaultAgentRawValue: String = "claudeCode"
    /// Drives session title, branch name, and worktree path together. See
    /// `SessionNamingSource`'s doc comment for why this used to be two
    /// settings and isn't anymore.
    public var namingSource: SessionNamingSource

    public init(
        createWorktreeByDefault: Bool = true,
        defaultAgentRawValue: String = "claudeCode",
        namingSource: SessionNamingSource = .appleIntelligence
    ) {
        self.createWorktreeByDefault = createWorktreeByDefault
        self.defaultAgentRawValue = defaultAgentRawValue
        self.namingSource = namingSource
    }

    /// Not `private`: `AppSettings.init(from:)` reads `.namingSource` and
    /// `.titleNamingSource` from a nested container keyed by this type to
    /// migrate a pre-merge settings file — see its doc comment.
    enum CodingKeys: String, CodingKey {
        case createWorktreeByDefault
        case defaultAgentRawValue
        case namingSource
        case titleNamingSource
        case agentManagedTitleEnabled
    }

    // Hand-written rather than synthesized: `SettingsStoring` decodes the
    // whole `AppSettings` tree with `try?`, so a throwing `Decodable` for a
    // key added after a user's settings file was already written would
    // silently reset every setting. `decodeIfPresent` with an explicit
    // default keeps old files decoding successfully.
    //
    // `titleNamingSource`/`agentManagedTitleEnabled` are the pre-merge keys
    // (back when title and worktree naming were separate settings). A file
    // written by an older build is decoded here on its own terms; the
    // cross-struct case where it disagreed with the old `git.worktreeNamingSource`
    // is resolved afterwards, in `AppSettings.init(from:)`, which prefers this
    // struct's value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        createWorktreeByDefault = try container.decodeIfPresent(Bool.self, forKey: .createWorktreeByDefault) ?? true
        if let source = try container.decodeIfPresent(SessionNamingSource.self, forKey: .namingSource) {
            namingSource = source
        } else if let legacyTitle = try container.decodeIfPresent(SessionNamingSource.self, forKey: .titleNamingSource) {
            namingSource = legacyTitle
        } else {
            // Preserve existing users' choice; only fresh settings default to AI.
            let legacy = try container.decodeIfPresent(Bool.self, forKey: .agentManagedTitleEnabled) ?? true
            namingSource = legacy ? .agentManaged : .promptDerived
        }
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

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(createWorktreeByDefault, forKey: .createWorktreeByDefault)
        try container.encode(defaultAgentRawValue, forKey: .defaultAgentRawValue)
        try container.encode(namingSource, forKey: .namingSource)
    }
}

public struct TerminalPreferences: Codable, Equatable, Sendable {
    public var fontSize: Double
    public var optionActsAsMeta: Bool
    public var scrollSpeed: Double
    public var gpuRendering: Bool
    public var editorFontSize: Double
    /// Opacity of the terminal's default cells. Explicit ANSI backgrounds,
    /// selections, and the caret remain fully opaque.
    public var backgroundOpacity: Double

    public init(
        fontSize: Double = 14,
        optionActsAsMeta: Bool = true,
        scrollSpeed: Double = 1,
        gpuRendering: Bool = false,
        editorFontSize: Double = 13,
        backgroundOpacity: Double = 0.42
    ) {
        self.fontSize = fontSize
        self.optionActsAsMeta = optionActsAsMeta
        self.scrollSpeed = scrollSpeed
        self.gpuRendering = gpuRendering
        self.editorFontSize = editorFontSize
        self.backgroundOpacity = backgroundOpacity
    }

    private enum CodingKeys: String, CodingKey {
        case fontSize, optionActsAsMeta, scrollSpeed, gpuRendering, editorFontSize, backgroundOpacity
    }

    // Hand-written rather than synthesized: `SettingsStoring` decodes the
    // whole `AppSettings` tree with `try?`, so a throwing `Decodable` for a
    // key added after a user's settings file was already written (like
    // `gpuRendering`) would silently reset every setting, not just this
    // struct's. `decodeIfPresent` with an explicit default keeps old files
    // decoding successfully. A settings file still carrying the removed
    // `naturalTextSelection` key (it was never wired to anything) simply
    // has that key ignored — CodingKeys no longer knows about it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 14
        optionActsAsMeta = try container.decodeIfPresent(Bool.self, forKey: .optionActsAsMeta) ?? true
        scrollSpeed = try container.decodeIfPresent(Double.self, forKey: .scrollSpeed) ?? 1
        gpuRendering = try container.decodeIfPresent(Bool.self, forKey: .gpuRendering) ?? false
        editorFontSize = try container.decodeIfPresent(Double.self, forKey: .editorFontSize) ?? 13
        backgroundOpacity = try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.42
    }
}

public enum NotificationDelivery: String, Codable, CaseIterable, Sendable, Identifiable {
    case never
    case onlyWhenNotActive
    case always

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .never: "Never"
        case .onlyWhenNotActive: "Only when not active"
        case .always: "Always"
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "never":
            self = .never
        case "onlyWhenNotActive", "only_when_not_active", "whenNotActive":
            self = .onlyWhenNotActive
        case "always":
            self = .always
        default:
            self = .always
        }
    }
}

public struct NotificationPreferences: Codable, Equatable, Sendable {
    public var delivery: NotificationDelivery
    public var waitingForInputEnabled: Bool
    public var finishedEnabled: Bool
    /// A session's GitHub CI went from passing or running to failing.
    public var ciFailedEnabled: Bool
    /// Shows how many sessions are waiting for input as a badge on the Dock
    /// icon. Independent of `delivery`: the badge is ambient state, not an
    /// interruption, so it stays useful with banners turned off.
    public var dockBadgeEnabled: Bool
    /// Shows the fleet's attention state as a status item in the menu bar.
    public var menuBarExtraEnabled: Bool

    public init(
        delivery: NotificationDelivery = .always,
        waitingForInputEnabled: Bool = true,
        finishedEnabled: Bool = true,
        ciFailedEnabled: Bool = true,
        dockBadgeEnabled: Bool = true,
        menuBarExtraEnabled: Bool = true
    ) {
        self.delivery = delivery
        self.waitingForInputEnabled = waitingForInputEnabled
        self.finishedEnabled = finishedEnabled
        self.ciFailedEnabled = ciFailedEnabled
        self.dockBadgeEnabled = dockBadgeEnabled
        self.menuBarExtraEnabled = menuBarExtraEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case delivery
        case waitingForInputEnabled
        case finishedEnabled
        case ciFailedEnabled
        case dockBadgeEnabled
        case menuBarExtraEnabled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        delivery = try container.decodeIfPresent(NotificationDelivery.self, forKey: .delivery) ?? .always
        waitingForInputEnabled = try container.decodeIfPresent(Bool.self, forKey: .waitingForInputEnabled) ?? true
        finishedEnabled = try container.decodeIfPresent(Bool.self, forKey: .finishedEnabled) ?? true
        ciFailedEnabled = try container.decodeIfPresent(Bool.self, forKey: .ciFailedEnabled) ?? true
        dockBadgeEnabled = try container.decodeIfPresent(Bool.self, forKey: .dockBadgeEnabled) ?? true
        menuBarExtraEnabled = try container.decodeIfPresent(Bool.self, forKey: .menuBarExtraEnabled) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(delivery, forKey: .delivery)
        try container.encode(waitingForInputEnabled, forKey: .waitingForInputEnabled)
        try container.encode(finishedEnabled, forKey: .finishedEnabled)
        try container.encode(ciFailedEnabled, forKey: .ciFailedEnabled)
        try container.encode(dockBadgeEnabled, forKey: .dockBadgeEnabled)
        try container.encode(menuBarExtraEnabled, forKey: .menuBarExtraEnabled)
    }

    public func shouldDeliver(isActive: Bool) -> Bool {
        switch delivery {
        case .never:
            return false
        case .onlyWhenNotActive:
            return !isActive
        case .always:
            return true
        }
    }

    public func shouldNotifyWaitingForInput(isActive: Bool) -> Bool {
        waitingForInputEnabled && shouldDeliver(isActive: isActive)
    }

    public func shouldNotifyCIFailed(isActive: Bool) -> Bool {
        ciFailedEnabled && shouldDeliver(isActive: isActive)
    }

    public func shouldNotifySessionFinished(isActive: Bool) -> Bool {
        finishedEnabled && shouldDeliver(isActive: isActive)
    }

    public var isConfiguredToNotify: Bool {
        delivery != .never && (waitingForInputEnabled || finishedEnabled || ciFailedEnabled)
    }
}

public struct GitPreferences: Codable, Equatable, Sendable {
    public var deleteBranchWithWorktree: Bool
    /// Which worktree option is pre-selected in the delete-session sheet.
    public var worktreeOnSessionDelete: WorktreeOnSessionDelete
    public var fetchBeforeCreatingWorktree: Bool
    /// Flags commits that landed since the last time a project's History view
    /// was opened. Off means the timeline treats every commit the same.
    public var highlightUnseenCommits: Bool
    /// How commits made inside agent sessions are attributed in projects that
    /// don't choose for themselves. Never changes commit authorship.
    public var defaultCommitAttribution: CommitAttributionMode
    /// Per-project choices, keyed by the project's UUID string. A project
    /// without an entry follows `defaultCommitAttribution`.
    public var projectCommitAttribution: [String: CommitAttributionMode]

    public init(
        deleteBranchWithWorktree: Bool = true,
        worktreeOnSessionDelete: WorktreeOnSessionDelete = .keep,
        fetchBeforeCreatingWorktree: Bool = false,
        highlightUnseenCommits: Bool = true,
        defaultCommitAttribution: CommitAttributionMode = .local,
        projectCommitAttribution: [String: CommitAttributionMode] = [:]
    ) {
        self.deleteBranchWithWorktree = deleteBranchWithWorktree
        self.worktreeOnSessionDelete = worktreeOnSessionDelete
        self.fetchBeforeCreatingWorktree = fetchBeforeCreatingWorktree
        self.highlightUnseenCommits = highlightUnseenCommits
        self.defaultCommitAttribution = defaultCommitAttribution
        self.projectCommitAttribution = projectCommitAttribution
    }

    /// The mode that applies to a project: its own choice, else the default.
    public func commitAttributionMode(forProject projectID: UUID?) -> CommitAttributionMode {
        guard let projectID, let chosen = projectCommitAttribution[projectID.uuidString] else {
            return defaultCommitAttribution
        }
        return chosen
    }

    private enum CodingKeys: String, CodingKey {
        case deleteBranchWithWorktree
        case worktreeOnSessionDelete
        case fetchBeforeCreatingWorktree
        case highlightUnseenCommits
        case defaultCommitAttribution
        case projectCommitAttribution
    }

    /// `stampAgentTrailer` is the on/off toggle attribution modes replaced —
    /// read only to seed `defaultCommitAttribution`, so someone who had
    /// turned attribution off doesn't find it switched back on.
    ///
    /// `worktreeNamingSource` is the pre-merge worktree-naming key (back
    /// when it was independent of `SessionDefaults.namingSource`). It isn't
    /// read here — `AppSettings.init(from:)` reads it directly, using this
    /// type, to migrate a file that still has it. See that type's doc
    /// comment.
    enum LegacyCodingKeys: String, CodingKey {
        case stampAgentTrailer
        case worktreeNamingSource
    }

    /// Decoded key by key rather than by the synthesized initializer: a
    /// settings file written by an older build has no `highlightUnseenCommits`
    /// key, and `SettingsStore` falls back to a default `AppSettings` on *any*
    /// decode error — so one missing key would silently reset every unrelated
    /// preference too.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deleteBranchWithWorktree = try container.decodeIfPresent(Bool.self, forKey: .deleteBranchWithWorktree) ?? true
        worktreeOnSessionDelete = try container.decodeIfPresent(WorktreeOnSessionDelete.self, forKey: .worktreeOnSessionDelete) ?? .keep
        fetchBeforeCreatingWorktree = try container.decodeIfPresent(Bool.self, forKey: .fetchBeforeCreatingWorktree) ?? false
        highlightUnseenCommits = try container.decodeIfPresent(Bool.self, forKey: .highlightUnseenCommits) ?? true
        if let mode = try? container.decodeIfPresent(CommitAttributionMode.self, forKey: .defaultCommitAttribution) {
            defaultCommitAttribution = mode
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let stamped = (try? legacy.decodeIfPresent(Bool.self, forKey: .stampAgentTrailer)) ?? true
            defaultCommitAttribution = stamped ? .local : .off
        }
        // Raw values, so one unknown mode from a newer build drops that entry
        // instead of failing the whole settings file.
        let rawProjectModes = (try? container.decodeIfPresent([String: String].self, forKey: .projectCommitAttribution)) ?? [:]
        projectCommitAttribution = rawProjectModes.compactMapValues(CommitAttributionMode.init(rawValue:))
    }
}

public struct WorkspacePreferences: Codable, Equatable, Sendable {
    public var selectedSessionID: String?
    public var viewMode: String
    public var detailPanel: String
    /// The grid's layout knob: how many columns to show, and how many rows
    /// fit the viewport before it scrolls. Set from the toolbar's grid-size
    /// picker (drag/click a cell in the N×M swatch).
    public var gridColumnCount: Int
    public var gridRowCount: Int
    /// Which sessions are assigned to the grid, in placement order. This is
    /// membership, not just ordering: the grid only ever renders sessions
    /// whose ID is in this list, capped at `gridColumnCount * gridRowCount`.
    public var gridSelectedSessionIDs: [String]
    /// "Dim unfocused sessions": every tile but the active one is faded by
    /// `gridDimIntensity` while this is on.
    public var gridDimEnabled: Bool
    /// 0...0.8 — how much to fade unfocused tiles when dimming is on.
    public var gridDimIntensity: Double
    /// Shows a text label under each sidebar rail icon (Overview/Sessions/
    /// Projects/New) instead of icon-only with a hover tooltip.
    public var sidebarRailLabels: Bool
    /// Which slice of the fleet the Sessions destination is showing, as
    /// chosen in the session group bar: `"all"`, `"general"`, or a project's
    /// UUID string. Stored as a string rather than an enum so SettingsKit
    /// stays free of the app's navigation types — `SessionGroup` in the app
    /// layer owns the parsing.
    public var sessionGroup: String
    /// Home's widget grid, in placement order. `nil` means the user never
    /// customized it and the app's default layout applies — so a later
    /// default change reaches everyone who hasn't built their own.
    public var homeWidgets: [HomeWidgetEntry]?
    /// Schema version of `homeWidgets`, for migrating saved layouts.
    public var homeWidgetsVersion: Int
    /// The one-time "Customize Home" hint has been shown and dismissed.
    public var homeCustomizeHintShown: Bool

    public init(
        selectedSessionID: String? = nil,
        viewMode: String = "single",
        detailPanel: String = "terminal",
        gridColumnCount: Int = 3,
        gridRowCount: Int = 2,
        gridSelectedSessionIDs: [String] = [],
        gridDimEnabled: Bool = false,
        gridDimIntensity: Double = 0.4,
        sidebarRailLabels: Bool = false,
        sessionGroup: String = "all",
        homeWidgets: [HomeWidgetEntry]? = nil,
        homeWidgetsVersion: Int = HomeWidgetEntry.currentVersion,
        homeCustomizeHintShown: Bool = false
    ) {
        self.selectedSessionID = selectedSessionID
        self.viewMode = viewMode
        self.detailPanel = detailPanel
        self.gridColumnCount = gridColumnCount
        self.gridRowCount = gridRowCount
        self.gridSelectedSessionIDs = gridSelectedSessionIDs
        self.gridDimEnabled = gridDimEnabled
        self.gridDimIntensity = gridDimIntensity
        self.sidebarRailLabels = sidebarRailLabels
        self.sessionGroup = sessionGroup
        self.homeWidgets = homeWidgets
        self.homeWidgetsVersion = homeWidgetsVersion
        self.homeCustomizeHintShown = homeCustomizeHintShown
    }

    private enum CodingKeys: String, CodingKey {
        case selectedSessionID, viewMode, detailPanel, gridColumnCount, gridRowCount
        case gridSelectedSessionIDs, gridDimEnabled, gridDimIntensity, sidebarRailLabels
        case sessionGroup, homeWidgets, homeWidgetsVersion, homeCustomizeHintShown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedSessionID = try container.decodeIfPresent(String.self, forKey: .selectedSessionID)
        viewMode = try container.decodeIfPresent(String.self, forKey: .viewMode) ?? "single"
        detailPanel = try container.decodeIfPresent(String.self, forKey: .detailPanel) ?? "terminal"
        gridColumnCount = try container.decodeIfPresent(Int.self, forKey: .gridColumnCount) ?? 3
        gridRowCount = try container.decodeIfPresent(Int.self, forKey: .gridRowCount) ?? 2
        gridSelectedSessionIDs = try container.decodeIfPresent([String].self, forKey: .gridSelectedSessionIDs) ?? []
        gridDimEnabled = try container.decodeIfPresent(Bool.self, forKey: .gridDimEnabled) ?? false
        gridDimIntensity = try container.decodeIfPresent(Double.self, forKey: .gridDimIntensity) ?? 0.4
        sidebarRailLabels = try container.decodeIfPresent(Bool.self, forKey: .sidebarRailLabels) ?? false
        sessionGroup = try container.decodeIfPresent(String.self, forKey: .sessionGroup) ?? "all"
        // A layout that fails to decode falls back to the default rather
        // than taking the rest of the settings file down with it.
        homeWidgets = (try? container.decodeIfPresent([HomeWidgetEntry].self, forKey: .homeWidgets)) ?? nil
        homeWidgetsVersion = try container.decodeIfPresent(Int.self, forKey: .homeWidgetsVersion) ?? HomeWidgetEntry.currentVersion
        homeCustomizeHintShown = try container.decodeIfPresent(Bool.self, forKey: .homeCustomizeHintShown) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(selectedSessionID, forKey: .selectedSessionID)
        try container.encodeIfPresent(viewMode, forKey: .viewMode)
        try container.encodeIfPresent(detailPanel, forKey: .detailPanel)
        try container.encodeIfPresent(gridColumnCount, forKey: .gridColumnCount)
        try container.encodeIfPresent(gridRowCount, forKey: .gridRowCount)
        try container.encodeIfPresent(gridSelectedSessionIDs, forKey: .gridSelectedSessionIDs)
        try container.encodeIfPresent(gridDimEnabled, forKey: .gridDimEnabled)
        try container.encodeIfPresent(gridDimIntensity, forKey: .gridDimIntensity)
        try container.encodeIfPresent(sidebarRailLabels, forKey: .sidebarRailLabels)
        try container.encodeIfPresent(sessionGroup, forKey: .sessionGroup)
        try container.encodeIfPresent(homeWidgets, forKey: .homeWidgets)
        try container.encode(homeWidgetsVersion, forKey: .homeWidgetsVersion)
        try container.encode(homeCustomizeHintShown, forKey: .homeCustomizeHintShown)
    }

}

/// One placed widget on Home. Kind and size are raw strings so SettingsKit
/// stays free of the app's widget types — `HomeWidgetKind` in the app layer
/// owns the parsing and drops kinds it doesn't know.
public struct HomeWidgetEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
    public static let currentVersion = 1

    public var id: UUID
    public var kind: String
    public var size: String
    public var config: HomeWidgetConfig

    public init(id: UUID = UUID(), kind: String, size: String, config: HomeWidgetConfig = HomeWidgetConfig()) {
        self.id = id
        self.kind = kind
        self.size = size
        self.config = config
    }
}

/// A widget instance's own settings. Every field is optional: `nil` is the
/// widget's default, which is what lets two copies of one widget differ.
public struct HomeWidgetConfig: Codable, Equatable, Hashable, Sendable {
    /// A project's UUID string; `nil` is "All projects".
    public var projectID: String?
    /// The widget's time window in days; `nil` is its default window.
    public var timeWindowDays: Int?
    /// An `AgentKind` raw value; `nil` is every agent.
    public var agent: String?

    public init(projectID: String? = nil, timeWindowDays: Int? = nil, agent: String? = nil) {
        self.projectID = projectID
        self.timeWindowDays = timeWindowDays
        self.agent = agent
    }

    public var isDefault: Bool { projectID == nil && timeWindowDays == nil && agent == nil }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var agentOverrides: AgentOverrides
    public var openCodeSubscription: OpenCodeSubscription
    public var worktreeBaseDirectory: String
    public var appearance: AppearanceMode
    /// Uses macOS's translucent, refractive surfaces across the workspace.
    /// Defaults on so existing installs adopt the new visual language.
    public var liquidGlassEnabled: Bool
    public var accentColor: String
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
                antigravityPath: agentOverrides.paths["antigravity"] ?? "",
                cursorAgentPath: agentOverrides.paths["cursorAgent"] ?? ""
            )
        }
        set {
            if newValue.claudeCodePath.isEmpty { agentOverrides.paths.removeValue(forKey: "claudeCode") } else { agentOverrides.paths["claudeCode"] = newValue.claudeCodePath }
            if newValue.codexCLIPath.isEmpty { agentOverrides.paths.removeValue(forKey: "codexCLI") } else { agentOverrides.paths["codexCLI"] = newValue.codexCLIPath }
            if newValue.openCodePath.isEmpty { agentOverrides.paths.removeValue(forKey: "openCode") } else { agentOverrides.paths["openCode"] = newValue.openCodePath }
            if newValue.antigravityPath.isEmpty { agentOverrides.paths.removeValue(forKey: "antigravity") } else { agentOverrides.paths["antigravity"] = newValue.antigravityPath }
            if newValue.cursorAgentPath.isEmpty { agentOverrides.paths.removeValue(forKey: "cursorAgent") } else { agentOverrides.paths["cursorAgent"] = newValue.cursorAgentPath }
        }
    }

    public var agentArguments: AgentArgumentOverrides {
        get {
            AgentArgumentOverrides(
                claudeCodeArguments: agentOverrides.arguments["claudeCode"] ?? [],
                codexCLIArguments: agentOverrides.arguments["codexCLI"] ?? [],
                openCodeArguments: agentOverrides.arguments["openCode"] ?? [],
                antigravityArguments: agentOverrides.arguments["antigravity"] ?? [],
                cursorAgentArguments: agentOverrides.arguments["cursorAgent"] ?? []
            )
        }
        set {
            if newValue.claudeCodeArguments.isEmpty { agentOverrides.arguments.removeValue(forKey: "claudeCode") } else { agentOverrides.arguments["claudeCode"] = newValue.claudeCodeArguments }
            if newValue.codexCLIArguments.isEmpty { agentOverrides.arguments.removeValue(forKey: "codexCLI") } else { agentOverrides.arguments["codexCLI"] = newValue.codexCLIArguments }
            if newValue.openCodeArguments.isEmpty { agentOverrides.arguments.removeValue(forKey: "openCode") } else { agentOverrides.arguments["openCode"] = newValue.openCodeArguments }
            if newValue.antigravityArguments.isEmpty { agentOverrides.arguments.removeValue(forKey: "antigravity") } else { agentOverrides.arguments["antigravity"] = newValue.antigravityArguments }
            if newValue.cursorAgentArguments.isEmpty { agentOverrides.arguments.removeValue(forKey: "cursorAgent") } else { agentOverrides.arguments["cursorAgent"] = newValue.cursorAgentArguments }
        }
    }

    public init(
        agentOverrides: AgentOverrides = AgentOverrides(),
        openCodeSubscription: OpenCodeSubscription = .none,
        worktreeBaseDirectory: String = "",
        appearance: AppearanceMode = .system,
        liquidGlassEnabled: Bool = true,
        accentColor: String = "original",
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
        self.liquidGlassEnabled = liquidGlassEnabled
        self.accentColor = accentColor
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
        liquidGlassEnabled: Bool = true,
        accentColor: String = "original",
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
        if !agentPaths.cursorAgentPath.isEmpty { paths["cursorAgent"] = agentPaths.cursorAgentPath }

        var arguments: [String: [String]] = [:]
        if !agentArguments.claudeCodeArguments.isEmpty { arguments["claudeCode"] = agentArguments.claudeCodeArguments }
        if !agentArguments.codexCLIArguments.isEmpty { arguments["codexCLI"] = agentArguments.codexCLIArguments }
        if !agentArguments.openCodeArguments.isEmpty { arguments["openCode"] = agentArguments.openCodeArguments }
        if !agentArguments.antigravityArguments.isEmpty { arguments["antigravity"] = agentArguments.antigravityArguments }
        if !agentArguments.cursorAgentArguments.isEmpty { arguments["cursorAgent"] = agentArguments.cursorAgentArguments }

        self.agentOverrides = AgentOverrides(paths: paths, arguments: arguments)
        self.openCodeSubscription = openCodeSubscription
        self.worktreeBaseDirectory = worktreeBaseDirectory
        self.appearance = appearance
        self.liquidGlassEnabled = liquidGlassEnabled
        self.accentColor = accentColor
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
        case liquidGlassEnabled
        case accentColor
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
        liquidGlassEnabled = try container.decodeIfPresent(Bool.self, forKey: .liquidGlassEnabled) ?? true
        accentColor = try container.decodeIfPresent(String.self, forKey: .accentColor) ?? "original"
        workspace = try container.decodeIfPresent(WorkspacePreferences.self, forKey: .workspace) ?? WorkspacePreferences()
        sessionDefaults = try container.decodeIfPresent(SessionDefaults.self, forKey: .sessionDefaults) ?? SessionDefaults()
        terminal = try container.decodeIfPresent(TerminalPreferences.self, forKey: .terminal) ?? TerminalPreferences()
        notifications = try container.decodeIfPresent(NotificationPreferences.self, forKey: .notifications) ?? NotificationPreferences()
        git = try container.decodeIfPresent(GitPreferences.self, forKey: .git) ?? GitPreferences()

        // Migrate a settings file from before title and worktree naming were
        // merged into `sessionDefaults.namingSource`. `SessionDefaults` above
        // already resolved its own legacy `titleNamingSource`/
        // `agentManagedTitleEnabled` keys in isolation; the one thing it
        // can't see from there is `git`'s legacy `worktreeNamingSource`. A
        // user who had explicitly set a title-naming preference keeps it
        // (title always won when the two could disagree); one who hadn't —
        // an old file with only `worktreeNamingSource` set — has that value
        // carried over instead of silently reverting to the fresh default.
        let sessionDefaultsHadExplicitValue: Bool = {
            guard let raw = try? container.nestedContainer(keyedBy: SessionDefaults.CodingKeys.self, forKey: .sessionDefaults) else { return false }
            if (try? raw.decodeIfPresent(SessionNamingSource.self, forKey: .namingSource)) != nil { return true }
            if (try? raw.decodeIfPresent(SessionNamingSource.self, forKey: .titleNamingSource)) != nil { return true }
            // The oldest format: a plain on/off toggle, from before naming
            // sources were even a three-way enum. Still an explicit title
            // choice, so it counts here too.
            if (try? raw.decodeIfPresent(Bool.self, forKey: .agentManagedTitleEnabled)) != nil { return true }
            return false
        }()
        if !sessionDefaultsHadExplicitValue,
           let gitContainer = try? container.nestedContainer(keyedBy: GitPreferences.LegacyCodingKeys.self, forKey: .git),
           let legacyWorktreeSource = try? gitContainer.decodeIfPresent(SessionNamingSource.self, forKey: .worktreeNamingSource) {
            sessionDefaults.namingSource = legacyWorktreeSource
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(agentOverrides, forKey: .agentOverrides)
        try container.encode(openCodeSubscription, forKey: .openCodeSubscription)
        try container.encode(worktreeBaseDirectory, forKey: .worktreeBaseDirectory)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(liquidGlassEnabled, forKey: .liquidGlassEnabled)
        try container.encode(accentColor, forKey: .accentColor)
        try container.encode(workspace, forKey: .workspace)
        try container.encode(sessionDefaults, forKey: .sessionDefaults)
        try container.encode(terminal, forKey: .terminal)
        try container.encode(notifications, forKey: .notifications)
        try container.encode(git, forKey: .git)
    }
}
