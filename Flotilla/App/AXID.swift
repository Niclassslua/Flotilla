import Foundation

/// Centralized accessibility identifiers for Flotilla.
/// All test targets import this file so a rename becomes a compile error
/// instead of a silent test failure.
public enum AXID: String, Sendable {
    // MARK: - Sidebar
    case sidebarList = "SidebarList"
    case sidebarOverview = "Sidebar.Overview"
    case sidebarProjectRow = "Sidebar.ProjectRow-"
    case sidebarProjectCollapseToggle = "Sidebar.ProjectRow.CollapseToggle-"
    case sidebarExpandAllProjects = "Sidebar.ExpandAllProjects"
    case sidebarCollapseAllProjects = "Sidebar.CollapseAllProjects"

    // MARK: - Toolbar
    case toolbarCommandPalette = "Toolbar.CommandPalette"
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
    case sessionBarScreenshotsToggle = "SessionBar.ScreenshotsToggle"

    // MARK: - Agent Screenshot Panel
    case agentScreenshotPanel = "AgentScreenshotPanel"
    case agentScreenshotPanelClose = "AgentScreenshotPanel.Close"
    case agentScreenshotPanelImage = "AgentScreenshotPanel.Image"
    case agentScreenshotViewerSheet = "AgentScreenshotViewerSheet"
    case agentScreenshotViewerPrevious = "AgentScreenshotViewerSheet.Previous"
    case agentScreenshotViewerNext = "AgentScreenshotViewerSheet.Next"
    case agentScreenshotViewerClose = "AgentScreenshotViewerSheet.Close"

    // MARK: - Git Sidebar
    case gitSidebar = "GitSidebar"
    case gitSidebarClose = "GitSidebar.Close"
    case gitSidebarChangesMode = "GitSidebar.Changes.Mode"
    case gitSidebarChangesList = "GitSidebar.Changes.List"
    case gitSidebarChangesCommitMessage = "GitSidebar.Changes.CommitMessage"
    case gitSidebarChangesCommit = "GitSidebar.Changes.Commit"
    case gitSidebarBranchesList = "GitSidebar.Branches.List"
    case gitSidebarBranchesName = "GitSidebar.Branches.Name"
    case gitSidebarBranchesCreate = "GitSidebar.Branches.Create"
    case gitSidebarBranchesNew = "GitSidebar.Branches.New"
    case gitSidebarLogList = "GitSidebar.Log.List"
    case gitSidebarLogBranch = "GitSidebar.Log.Branch"
    case gitSidebarActionError = "GitSidebar.ActionError"

    // MARK: - Command Palette
    case commandPaletteSearch = "CommandPalette.Search"

    // MARK: - Create Session
    case createSessionGoalField = "CreateSession.GoalField"
    case createSessionProjectPicker = "CreateSession.ProjectPicker"
    case createSessionEffortPicker = "CreateSession.EffortPicker"
    case createSessionCreateButton = "CreateSession.CreateButton"
    case createSessionBackgroundButton = "CreateSession.BackgroundButton"
    case createSessionCancelButton = "CreateSession.CancelButton"
    case createSessionChooseFolderButton = "CreateSession.ChooseFolderButton"
    case createSessionSourceGeneral = "CreateSession.Source.General"
    case createSessionAgentOption = "CreateSession.Agent."
    case createSessionCheckoutMain = "CreateSession.Checkout.Main"
    case createSessionCheckoutWorktree = "CreateSession.Checkout.Worktree"
    case createSessionModelField = "CreateSession.ModelField"
    case createSessionLaunchSummary = "CreateSession.LaunchSummary"
    case createSessionAttachments = "CreateSession.Attachments"
    case createSessionAttachmentRemove = "CreateSession.Attachment.Remove"

    // MARK: - Grid View
    case gridView = "GridView"
    case gridTile = "GridTile-"
    case gridTileStatus = "GridTile-Status-"
    case gridTileFocusButton = "GridTile-FocusButton-"
    case gridLayoutPicker = "GridLayout.Picker"
    case gridLayoutPickerCell = "GridLayout.Picker.Cell-"
    case gridAddAllButton = "Grid.AddAllButton"
    case gridEmptyButton = "Grid.EmptyButton"
    case gridDimButton = "Grid.DimButton"

    // MARK: - Kanban
    case kanbanBoard = "KanbanBoard"
    case kanbanColumn = "KanbanColumn-"
    case kanbanCard = "KanbanCard-"

    // MARK: - Inspector

    // MARK: - Session Details

    // MARK: - Settings
    case settingsAppearancePicker = "Settings.AppearancePicker"
    case settingsNotificationDeliveryPicker = "Settings.NotificationDeliveryPicker"
    case settingsWorktreeBaseDirectory = "Settings.WorktreeBaseDirectory"
    case settingsWorktreeOnSessionDelete = "Settings.WorktreeOnSessionDelete"
    case settingsScreenRecordingPermissionRow = "Settings.ScreenRecordingPermissionRow"
    case settingsGrantScreenRecordingPermission = "Settings.GrantScreenRecordingPermission"
    case settingsOpenScreenRecordingSettings = "Settings.OpenScreenRecordingSettings"
    case settingsRefreshScreenRecordingPermission = "Settings.RefreshScreenRecordingPermission"
    case settingsView = "SettingsView"

    // MARK: - Delete Session Dialog
    case deleteSessionCancel = "DeleteSessionDialog.Cancel"
    case deleteSessionKeepWorktreeOption = "DeleteSessionDialog.KeepWorktreeOption"
    case deleteSessionRemoveWorktreeOption = "DeleteSessionDialog.RemoveWorktreeOption"
    case deleteSessionKeepWorktree = "DeleteSessionDialog.KeepWorktreeDeleteSession"
    case deleteSessionDeleteWithWorktree = "DeleteSessionDialog.DeleteWithWorktree"
    case deleteSessionDeleteOnly = "DeleteSessionDialog.DeleteSessionOnly"

    // MARK: - Global / Misc
    case startupWarningBanner = "StartupWarningBanner"
    case startupWarningBannerDismissButton = "StartupWarningBanner.DismissButton"
    case lastNotifiedSession = "LastNotifiedSession"
    case detailPlaceholder = "DetailPlaceholder"
    case gridEmptyState = "GridEmptyState"
    case restartSessionButton = "Restart Session"

    // MARK: - Agent Exit Screen
    case agentExitScreen = "AgentExitScreen"
    case agentExitShowOutput = "AgentExitScreen.ShowOutput"
    case agentExitRestart = "AgentExitScreen.Restart"
    case agentExitStripRestart = "AgentExitStrip.Restart"
    case newSessionButton = "NewSessionButton"
    case openSessionButton = "Open Session"

    // MARK: - Diff Panel
    case diffPanel = "DiffPanel"
    case diffPanelFile = "DiffPanel.File-"
    case diffPanelEmpty = "DiffPanel.Empty"
    case diffPanelList = "DiffPanel.List"
    case diffPanelRefreshButton = "DiffPanel.RefreshButton"
    case diffPanelSimulateEditButton = "DiffPanel.SimulateEditButton"

    // MARK: - File Browser
    case fileBrowser = "FileBrowser"
    case fileBrowserEditor = "FileBrowser.Editor"
    case fileBrowserRow = "FileBrowser.Row-"

    // MARK: - Rules Panel
    case rulesPanel = "RulesPanel"

    // MARK: - Project
    case projectRow = "ProjectRow-"
    case projectOverview = "ProjectOverview"
    case projectWorktreesSection = "ProjectWorktreesSection"
    case projectReturnToOverview = "Project.ReturnToOverview"

    // MARK: - Project Tabs
    case projectTabGit = "ProjectDetail.ModeTab-Git"
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
    case homeRecentProjects = "Home.RecentProjects"
    case homeGreeting = "Home.Greeting"
    // MARK: - Home Widget Grid
    case homeWidgetGrid = "Home.Widgets.Grid"
    case homeWidgetEditButton = "Home.Widgets.EditButton"
    case homeWidgetDoneButton = "Home.Widgets.DoneButton"
    case homeWidgetAddButton = "Home.Widgets.AddButton"
    case homeWidgetGallery = "Home.Widgets.Gallery"
    case homeWidgetEmptyState = "Home.Widgets.EmptyState"
    case homeWidgetEmptyAddButton = "Home.Widgets.EmptyState.AddButton"
    case homeWidgetGalleryAddButton = "Home.Widgets.Gallery.Add-"
    case homeWidgetResetButton = "Home.Widgets.ResetButton"
    case homeWidgetSettingsPopover = "Home.Widgets.SettingsPopover"
    /// Suffixed with the widget kind's raw value, e.g. `Home.Widget-streak`.
    case homeWidget = "Home.Widget-"
    case homeWidgetRemoveBadge = "Home.Widget.Remove-"
    case homeWidgetInfoBadge = "Home.Widget.Info-"
    case homeWidgetResizeHandle = "Home.Widget.Resize-"
    case homeWidgetSkeleton = "Home.Widget.Skeleton-"

    // MARK: - Session Row (Legacy - preserved for test compatibility)
    case sessionRow = "SessionRow-"
    case sessionRowDeleteMenuItem = "SessionRow-DeleteMenuItem"

    // MARK: - Session Toolbar (Legacy - preserved for test compatibility)

    // MARK: - Global Bar (Legacy - preserved for test compatibility)

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

    /// Creates a diff panel file row identifier from a path
    public static func diffPanelFile(_ path: String) -> String {
        "DiffPanel.File-\(path)"
    }

    /// Creates a file browser row identifier from a name
    public static func fileBrowserRow(_ name: String) -> String {
        "FileBrowser.Row-\(name)"
    }

    /// Creates a git sidebar tab identifier
    public static func gitSidebarTab(_ title: String) -> String {
        "GitSidebar.Tab.\(title)"
    }

    /// Creates a git sidebar commit row identifier
    public static func gitSidebarLogCommit(_ shortSHA: String) -> String {
        "GitSidebar.Log.Commit-\(shortSHA)"
    }

    /// Creates a git sidebar change file row identifier
    public static func gitSidebarChangesFile(_ path: String) -> String {
        "GitSidebar.Changes.File-\(path)"
    }

    /// Creates a git sidebar change stage button identifier
    public static func gitSidebarChangesStage(_ path: String) -> String {
        "GitSidebar.Changes.Stage-\(path)"
    }

    /// Creates a git sidebar branch row identifier
    public static func gitSidebarBranchesRow(_ branch: String) -> String {
        "GitSidebar.Branches.Row-\(branch)"
    }

    /// Creates a sidebar project row identifier
    public static func sidebarProjectRow(_ name: String) -> String {
        "Sidebar.ProjectRow-\(name)"
    }

    /// Creates a sidebar project row's collapse-toggle identifier
    public static func sidebarProjectCollapseToggle(_ name: String) -> String {
        "Sidebar.ProjectRow.CollapseToggle-\(name)"
    }

    /// Creates a toolbar presentation show button identifier
    public static func toolbarShow(_ title: String) -> String {
        "Toolbar.Show\(title)"
    }

    /// Creates a knowledge catalog item identifier
    public static func knowledgeItem(_ title: String) -> String {
        "Knowledge.Item-\(title)"
    }

    /// Creates a kanban card identifier
    public static func kanbanCard(_ title: String) -> String {
        "KanbanCard-\(title)"
    }

    /// Creates a kanban column header identifier
    public static func kanbanColumnHeader(_ title: String) -> String {
        "KanbanColumn-\(title)-Header"
    }

    /// Creates a terminal view identifier
    public static func terminalView(_ title: String) -> String {
        "TerminalView-\(title)"
    }

    /// Creates a session row status identifier
    public static func sessionRowStatus(_ title: String) -> String {
        "SessionRow-\(title)-Status"
    }

    /// Creates a session row delete button identifier

    /// Creates a session row delete context menu item identifier
    public static func sessionRowDeleteMenuItem(_ title: String) -> String {
        "SessionRow-\(title)-DeleteMenuItem"
    }

    /// Creates a settings sidebar tab identifier
    public static func settingsSidebarTab(_ tab: String) -> String {
        "settings.sidebar.\(tab)"
    }

    /// Creates a create session agent option identifier
    public static func createSessionAgentOption(_ agent: String) -> String {
        "CreateSession.Agent.\(agent)"
    }

    /// Creates a project git sub-tab identifier
    public static func projectGitSubTab(_ title: String) -> String {
        "ProjectGit.SubTab-\(title)"
    }
}
