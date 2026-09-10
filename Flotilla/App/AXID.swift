import Foundation

/// Centralized accessibility identifiers for Flotilla.
/// All test targets import this file so a rename becomes a compile error
/// instead of a silent test failure.
public enum AXID: String, Sendable {
    // MARK: - Sidebar
    case sidebarList = "SidebarList"
    case sidebarOverview = "Sidebar.Overview"
    case sidebarAllSessions = "Sidebar.AllSessions"
    case sidebarAllProjects = "Sidebar.AllProjects"
    case sidebarProjectRow = "Sidebar.ProjectRow-"
    case sidebarSessionRow = "Sidebar.SessionRow-"

    // MARK: - Toolbar
    case toolbarNewSession = "Toolbar.NewSession"
    case toolbarCommandPalette = "Toolbar.CommandPalette"
    case toolbarInspectorToggle = "Toolbar.InspectorToggle"
    case toolbarOverflow = "Toolbar.Overflow"
    /// The two destination buttons that replaced the segmented presentation
    /// picker. Each lands in Sessions with that presentation live, from
    /// wherever the user currently is.
    case toolbarShowGrid = "Toolbar.ShowGrid"
    case toolbarShowBoard = "Toolbar.ShowBoard"
    case toolbarSettings = "Toolbar.Settings"
    case toolbarBack = "Toolbar.Back"
    case toolbarForward = "Toolbar.Forward"
    case topBarLogo = "TopBar.Logo"
    /// Moved from the window toolbar onto the session bar and kept its
    /// identifier: it names the same action on the same session, and the
    /// UI-test lookups already depend on the spelling.
    case toolbarOpenProjectFiles = "Toolbar.OpenProjectFiles"

    // MARK: - Session group bar
    case sessionsGroupBar = "Sessions.GroupBar"
    case sessionsGroup = "Sessions.Group-"

    // MARK: - Session bar
    /// Session-scoped, because the grid renders one bar per tile: a flat
    /// `"SessionBar.Title"` would match up to `columns × rows` elements at
    /// once. The focus variant is the same bar with the same naming.
    case sessionBar = "SessionBar-"
    /// Focus-variant only, and there is exactly one focused session, so this
    /// one needs no title.
    case sessionBarGitSidebarToggle = "SessionBar.GitSidebarToggle"

    // MARK: - Command Palette
    case commandPaletteButton = "CommandPaletteButton"
    case commandPaletteInput = "CommandPalette.Input"
    case commandPaletteResult = "CommandPalette.Result-"

    // MARK: - Create Session
    case createSessionGoalField = "CreateSession.GoalField"
    case createSessionProjectPicker = "CreateSession.ProjectPicker"
    case createSessionAgentPicker = "CreateSession.AgentPicker"
    case createSessionModelPicker = "CreateSession.ModelPicker"
    case createSessionEffortPicker = "CreateSession.EffortPicker"
    case createSessionWorktreeToggle = "CreateSession.WorktreeToggle"
    case createSessionLaunchButton = "CreateSession.LaunchButton"
    case createSessionCreateButton = "CreateSession.CreateButton"
    case createSessionBackgroundButton = "CreateSession.BackgroundButton"
    case createSessionCancelButton = "CreateSession.CancelButton"
    case createSessionChooseFolderButton = "CreateSession.ChooseFolderButton"
    case createSessionSourceGeneral = "CreateSession.Source.General"
    case createSessionProjectRow = "CreateSession.Project-"
    case createSessionAgentOption = "CreateSession.Agent."
    case createSessionCheckoutMain = "CreateSession.Checkout.Main"
    case createSessionCheckoutWorktree = "CreateSession.Checkout.Worktree"
    case createSessionModelField = "CreateSession.ModelField"
    case createSessionLaunchSummary = "CreateSession.LaunchSummary"

    // MARK: - Grid View
    case gridView = "GridView"
    case gridTile = "GridTile-"
    case gridTileStatus = "GridTile-Status-"
    case gridTileFocusButton = "GridTile-FocusButton-"
    case gridLayoutPicker = "GridLayout.Picker"
    case gridLayoutPickerCell = "GridLayout.Picker.Cell-"

    // MARK: - Kanban
    case kanbanBoard = "KanbanBoard"
    case kanbanColumn = "KanbanColumn-"
    case kanbanCard = "KanbanCard-"

    // MARK: - Inspector
    case inspectorTabChanges = "Inspector.Tab.Changes"
    case inspectorTabFiles = "Inspector.Tab.Files"
    case inspectorTabInstructions = "Inspector.Tab.Instructions"
    case inspectorTabDetails = "Inspector.Tab.Details"

    // MARK: - Session Details
    case sessionDetailsPopover = "SessionDetailsPopover"

    // MARK: - Settings
    case settingsAppearancePicker = "Settings.AppearancePicker"
    case settingsGeneralTab = "Settings.GeneralTab"
    case settingsTerminalTab = "Settings.TerminalTab"
    case settingsAgentsTab = "Settings.AgentsTab"
    case settingsNotificationsTab = "Settings.NotificationsTab"
    case settingsGitTab = "Settings.GitTab"
    case settingsAdvancedTab = "Settings.AdvancedTab"

    // MARK: - Delete Session Dialog
    case deleteSessionCancel = "DeleteSessionDialog.Cancel"
    case deleteSessionKeepWorktree = "DeleteSessionDialog.KeepWorktreeDeleteSession"
    case deleteSessionDeleteWithWorktree = "DeleteSessionDialog.DeleteWithWorktree"
    case deleteSessionDeleteOnly = "DeleteSessionDialog.DeleteSessionOnly"

    // MARK: - Global / Misc
    case globalRestoreStopped = "Global.Restore stopped sessions"
    case startupWarningBanner = "StartupWarningBanner"
    case lastNotifiedSession = "LastNotifiedSession"
    case detailPlaceholder = "DetailPlaceholder"
    case gridEmptyState = "GridEmptyState"
    case viewModePicker = "ViewModePicker"
    case restartSessionButton = "Restart Session"

    // MARK: - Diff Panel
    case diffPanel = "DiffPanel"
    case diffPanelFile = "DiffPanel.File-"
    case diffPanelHunk = "DiffPanel.Hunk-"

    // MARK: - File Browser
    case fileBrowser = "FileBrowser"
    case fileBrowserNavigator = "FileBrowser.Navigator"
    case fileBrowserEditor = "FileBrowser.Editor"
    case fileBrowserTree = "FileBrowser.Tree-"

    // MARK: - Rules Panel
    case rulesPanel = "RulesPanel"
    case rulesPanelFileList = "RulesPanel.FileList"
    case rulesPanelEditor = "RulesPanel.Editor"
    case rulesPanelFilter = "RulesPanel.Filter"

    // MARK: - Project
    case projectRow = "ProjectRow-"
    case projectCompactCard = "ProjectCompactCard-"
    case projectSidebarHeader = "ProjectSidebarHeader"
    case projectWorkspaceDetail = "ProjectWorkspaceDetail"
    case projectOverview = "ProjectOverview"
    case projectSessionsSection = "ProjectSessionsSection"
    case projectWorktreesSection = "ProjectWorktreesSection"
    case projectsCommandCenter = "Projects.CommandCenter"
    case projectsMetricStrip = "Projects.MetricStrip"
    case projectCardQuickLaunch = "ProjectCard.QuickLaunch-"
    case projectCardTerminal = "ProjectCard.Terminal-"
    case projectCardEditor = "ProjectCard.Editor-"
    case projectCardFinder = "ProjectCard.Finder-"
    case projectModeOverview = "Project.Mode.Overview"
    case projectModeWorktrees = "Project.Mode.Worktrees"
    case projectModePipeline = "Project.Mode.Pipeline"
    case projectModeContext = "Project.Mode.Context"
    case worktreeTable = "Worktree.Table"
    case worktreePruneButton = "Worktree.PruneButton-"
    case worktreeMergeButton = "Worktree.MergeButton-"

    // MARK: - Project Tabs
    case projectTabOverview = "ProjectDetail.ModeTab-Overview"
    case projectTabGit = "ProjectDetail.ModeTab-Git"
    case projectTabFiles = "ProjectDetail.ModeTab-Files"
    case projectTabSkills = "ProjectDetail.ModeTab-Skills"
    case projectTabRules = "ProjectDetail.ModeTab-Rules"
    case projectFiles = "ProjectFiles"
    case projectSkills = "ProjectSkills"
    case projectRules = "ProjectRules"

    // MARK: - Knowledge (Skills & Rules catalog)
    case knowledgeSearchField = "Knowledge.SearchField"
    case knowledgeScopeFilter = "Knowledge.ScopeFilter"
    case knowledgeSortMenu = "Knowledge.SortMenu"
    case knowledgeRefresh = "Knowledge.Refresh"
    case knowledgeAddTemplate = "Knowledge.AddTemplate"
    /// Suffixed with the item's title, e.g. `Knowledge.Item-CLAUDE.md`.
    case knowledgeItem = "Knowledge.Item-"
    case knowledgeDetailReader = "Knowledge.Detail.Reader"
    case knowledgeDetailEditor = "Knowledge.Detail.Editor"
    case knowledgeEditButton = "Knowledge.Detail.Edit"
    case knowledgeSaveButton = "Knowledge.Detail.Save"
    case knowledgeSaveStatus = "Knowledge.Detail.SaveStatus"
    case knowledgeNoSelection = "Knowledge.NoSelection"

    // MARK: - Home Dashboard
    case homeDashboard = "HomeDashboard"
    case homeGoalField = "Home.GoalField"
    case homeRecentProjects = "Home.RecentProjects"
    case homeRecentSessions = "Home.RecentSessions"
    case homeAttentionQueue = "Home.AttentionQueue"
    case homeAgentOption = "Home.Agent."
    case homeProjectFilter = "Home.ProjectFilter"
    case homeProjectTile = "Home.Project-"
    case homeSourceGeneral = "Home.Source.General"
    case homeChooseFolderButton = "Home.ChooseFolderButton"
    case homeCheckoutMain = "Home.Checkout.Main"
    case homeCheckoutWorktree = "Home.Checkout.Worktree"
    case homeModelField = "Home.ModelField"
    case homeEffortPicker = "Home.EffortPicker"
    case homeLaunchSummary = "Home.LaunchSummary"
    case homeLaunchButton = "Home.LaunchButton"
    case projectCompactCardEllipsis = "ProjectCompactCard.Ellipsis-"

    // MARK: - Session Row (Legacy - preserved for test compatibility)
    case sessionRow = "SessionRow-"
    case sessionRowDeleteButton = "SessionRow-DeleteButton"
    case sessionRowDeleteMenuItem = "SessionRow-DeleteMenuItem"

    // MARK: - Session Toolbar (Legacy - preserved for test compatibility)
    case sessionGitInspectorButton = "Session.GitInspectorButton"

    // MARK: - Global Bar (Legacy - preserved for test compatibility)
    case globalOverview = "Global.Overview"
    case globalSessions = "Global.Sessions"
    case globalProjects = "Global.Projects"
    case globalKanban = "Global.Kanban"

    // MARK: - Review
    case reviewWindow = "Review.Window"
    case reviewEmpty = "Review.Empty"
    case reviewFileList = "Review.FileList"
    case reviewDiffPane = "Review.DiffPane"
    case reviewStaleBanner = "Review.StaleBanner"
    case reviewRefresh = "Review.Refresh"
    case reviewProgress = "Review.Progress"
    case reviewScopeBranch = "Review.Scope.Branch"
    case reviewScopeUncommitted = "Review.Scope.Uncommitted"
    /// The two layout buttons the review is specified around. UI tests assert
    /// on which one is selected and that the diff rendering follows.
    case reviewModeSideBySide = "Review.Mode.SideBySide"
    case reviewModeInline = "Review.Mode.Inline"
    /// On the rendered hunk, not the button — so a test can tell that
    /// selecting a mode actually changed the layout, rather than only that
    /// the button looked selected.
    case reviewHunkInline = "Review.Hunk.Inline"
    case reviewHunkSideBySide = "Review.Hunk.SideBySide"
    case reviewDisplayAllFiles = "Review.Display.AllFiles"
    case reviewDisplaySingleFile = "Review.Display.SingleFile"
    case reviewWrapLines = "Review.WrapLines"
    case reviewSend = "Review.Send"
    case reviewSendSheet = "Review.SendSheet"
    case reviewCommentEditor = "Review.CommentEditor"
    case reviewCommentSubmit = "Review.CommentSubmit"
    case reviewCommentCancel = "Review.CommentCancel"

    // MARK: - Helpers
    /// Creates a session row identifier from a title
    public static func sessionRow(_ title: String) -> String {
        "SessionRow-\(title)"
    }

    /// Creates a grid tile identifier from a title
    public static func gridTile(_ title: String) -> String {
        "GridTile-\(title)"
    }

    /// Creates a grid tile status identifier from a title
    public static func gridTileStatus(_ title: String) -> String {
        "GridTile-\(title)-Status"
    }

    /// Creates a grid tile focus button identifier from a title
    public static func gridTileFocusButton(_ title: String) -> String {
        "GridTile-\(title)-FocusButton"
    }

    /// Creates a grid tile "remove from grid" button identifier from a title
    public static func gridTileRemoveButton(_ title: String) -> String {
        "GridTile-\(title)-RemoveButton"
    }

    /// Creates a session group chip identifier. `name` is the chip's own
    /// label — "All", "General", or a project name.
    public static func sessionsGroup(_ name: String) -> String {
        "Sessions.Group-\(name)"
    }

    /// The session bar's own identifiers, all keyed by the session's title so
    /// a grid full of bars stays unambiguous.
    public static func sessionBar(_ title: String) -> String {
        "SessionBar-\(title)"
    }

    public static func sessionBarTitle(_ title: String) -> String {
        "SessionBar-\(title)-Title"
    }

    public static func sessionBarTitleField(_ title: String) -> String {
        "SessionBar-\(title)-TitleField"
    }

    public static func sessionBarBranch(_ title: String) -> String {
        "SessionBar-\(title)-Branch"
    }

    public static func sessionBarWorktree(_ title: String) -> String {
        "SessionBar-\(title)-Worktree"
    }

    public static func sessionBarHandoff(_ title: String) -> String {
        "SessionBar.Handoff.\(title)"
    }

    public static func sessionBarAge(_ title: String) -> String {
        "SessionBar-\(title)-Age"
    }

    public static func sessionBarStatus(_ title: String) -> String {
        "SessionBar-\(title)-Status"
    }

    /// Creates a project row identifier from a name
    public static func projectRow(_ name: String) -> String {
        "ProjectRow-\(name)"
    }

    /// Creates a worktree row identifier from its branch name — the context
    /// rail keys its rows by branch, which is unique per worktree.
    public static func worktreeRow(_ branch: String) -> String {
        "Project.WorktreeRow-\(branch)"
    }

    /// Creates a commit-week-chart bar identifier, keyed by how many days back
    /// the bar sits (0 is today).
    public static func commitWeekChartDay(_ daysAgo: Int) -> String {
        "Project.CommitWeekChart.Day-\(daysAgo)"
    }

    /// Creates a command palette result identifier
    public static func commandPaletteResult(_ index: Int) -> String {
        "CommandPalette.Result-\(index)"
    }

    /// Opens the review window for a session, from its session bar.
    public static func sessionBarReview(_ title: String) -> String {
        "SessionBar.Review.\(title)"
    }

    /// A row in the review's file list, keyed by repository-relative path —
    /// unique per review, unlike the filename.
    public static func reviewFileRow(_ path: String) -> String {
        "Review.FileRow-\(path)"
    }

    /// The viewed tick on a review file row.
    public static func reviewFileViewed(_ path: String) -> String {
        "Review.FileViewed-\(path)"
    }

    /// A file's section header in the diff pane, which is also the scroll
    /// anchor the file list jumps to.
    public static func reviewFileSection(_ path: String) -> String {
        "Review.FileSection-\(path)"
    }

    /// One rendered diff line. `side` is `old` or `new`, matching
    /// `ReviewSide`; a side-by-side row exposes both halves separately.
    public static func reviewDiffLine(_ path: String, side: String, line: Int) -> String {
        "Review.DiffLine-\(path)-\(side)-\(line)"
    }

    /// The "comment on this file" button in a file's section header.
    public static func reviewCommentOnFile(_ path: String) -> String {
        "Review.CommentOnFile-\(path)"
    }

    /// A destination row in the send sheet.
    public static func reviewSendDestination(_ label: String) -> String {
        "Review.SendDestination-\(label)"
    }
}
