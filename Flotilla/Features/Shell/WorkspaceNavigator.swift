import Foundation
import GitKit
import Observation
import SessionKit
import SwiftUI

@Observable
@MainActor
final class WorkspaceNavigator {
    var selection: SidebarItem = .overview {
        didSet {
            guard selection != oldValue else { return }
            switch selection {
            case .overview, .project:
                lastOverviewSelection = selection
            case .allSessions, .smartList, .session:
                break
            }
            sidebarSelection = selection == .overview ? [] : [selection]
            recordHistory(from: oldValue)
        }
    }
    /// Mirrors visible List rows for native multi-select. Home is a separate
    /// button above the List, so it has no List selection tag.
    /// A plain click narrows this to one tag and `FlotillaShell` folds that
    /// back into `selection`; ⌘/Shift-click grow it to more than one so rows
    /// can be batch-selected (e.g. for Delete) without changing what's open
    /// in the detail column. Kept in sync whenever `selection` changes
    /// through any other path (keyboard shortcuts, the command palette,
    /// restoring state) via `selection`'s `didSet` above.
    var sidebarSelection: Set<SidebarItem> = []
    var presentation: WorkspacePresentation = ProcessInfo.processInfo.environment["UI_TESTING"] == "1" ? .focus : .grid
    /// Which group chip is lit in the session group bar. Kept here rather
    /// than inside Grid or Board so both presentations read one value and
    /// switching between them cannot change what is on screen.
    var sessionGroup: SessionGroup = .all
    var presentedSheet: WorkspaceSheet?
    var columnVisibility: NavigationSplitViewVisibility = .all
    var searchText = ""
    private(set) var lastOverviewSelection: SidebarItem = .overview
    private var projectTabs: [UUID: ProjectDetailView.ProjectTab] = [:]
    private var projectGitScopes: [UUID: URL] = [:]
    private var projectGitSubTabs: [UUID: ProjectGitView.GitSubTab] = [:]
    @ObservationIgnored private var fileBrowserViewModels: [URL: FileBrowserViewModel] = [:]
    @ObservationIgnored private var projectGraphViewModels: [URL: ProjectGraphViewModel] = [:]
    @ObservationIgnored private var diffPanelViewModels: [URL: DiffPanelViewModel] = [:]
    @ObservationIgnored private var sessionGitSidebarViewModels: [URL: SessionGitSidebarViewModel] = [:]

    // Legacy compatibility - one-way flow from navigator to store
    var selectedSessionID: UUID? {
        get {
            if case .session(let id) = selection { return id }
            return nil
        }
        set {
            if let newValue { selection = .session(newValue) }
        }
    }

    var selectedProjectID: UUID? {
        get {
            if case .project(let id) = selection { return id }
            return nil
        }
        set {
            if let newValue { selection = .project(newValue) }
        }
    }

    // MARK: - History

    /// Where the user has been, so Back returns them there. The app shipped
    /// with no way to get back to a previous location at all.
    ///
    /// `isNavigatingHistory` suppresses recording while Back/Forward are
    /// themselves moving `selection`, which would otherwise push the move onto
    /// the very stack it is popping.
    private(set) var backStack: [SidebarItem] = []
    private(set) var forwardStack: [SidebarItem] = []
    private var isNavigatingHistory = false

    private static let historyLimit = 50

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    private func recordHistory(from previous: SidebarItem) {
        guard !isNavigatingHistory else { return }
        backStack.append(previous)
        if backStack.count > Self.historyLimit { backStack.removeFirst() }
        // A fresh navigation abandons any forward branch, the same way a
        // browser does.
        forwardStack.removeAll()
    }

    func goBack() {
        guard let destination = backStack.popLast() else { return }
        isNavigatingHistory = true
        forwardStack.append(selection)
        selection = destination
        isNavigatingHistory = false
    }

    func goForward() {
        guard let destination = forwardStack.popLast() else { return }
        isNavigatingHistory = true
        backStack.append(selection)
        selection = destination
        isNavigatingHistory = false
    }

    // MARK: - Scope

    /// What the collection surfaces should render. Grid, Board and Focus all
    /// read this one value, so switching presentation changes how the fleet is
    /// shown and never what is in it.
    /// The group narrows the fleet; a smart list narrows it again. Selecting
    /// a project in the navigator is itself a project scope, and there it
    /// wins over the bar's group — the group bar is not on screen in project
    /// scope, so a stale chip must not silently filter a project workspace.
    var sessionScope: SessionScope {
        switch selection {
        case .smartList(let list): SessionScope(group: sessionGroup, smartList: list)
        case .project(let id): SessionScope(group: .project(id), smartList: nil)
        case .overview, .allSessions, .session: SessionScope(group: sessionGroup, smartList: nil)
        }
    }

    /// Drops a group whose project no longer exists. Without this a deleted
    /// project leaves the grid permanently filtered to nothing, with the
    /// chip that explains why gone from the bar as well.
    func pruneSessionGroup(against projectIDs: Set<UUID>) {
        guard case .project(let id) = sessionGroup, !projectIDs.contains(id) else { return }
        sessionGroup = .all
    }

    /// Returns to the place the user last occupied on the Home side.
    /// Sessions are a sibling workspace, so visiting them must not flatten a
    /// project's internal navigation back to its dashboard.
    func restoreHomeSelection() {
        selection = lastOverviewSelection
    }

    /// Intentionally leaves a project drill-down for the overview dashboard.
    func showHomeDashboard() {
        selection = .overview
    }

    func projectTab(for projectID: UUID) -> ProjectDetailView.ProjectTab {
        projectTabs[projectID] ?? .overview
    }

    func setProjectTab(_ tab: ProjectDetailView.ProjectTab, for projectID: UUID) {
        projectTabs[projectID] = tab
    }

    func projectGitScope(for projectID: UUID) -> URL? {
        projectGitScopes[projectID]
    }

    func setProjectGitScope(_ scope: URL?, for projectID: UUID) {
        projectGitScopes[projectID] = scope
    }

    /// Jumps from a focused session into the project's Git/Files/Rules tab,
    /// scoping the Git tab to that session's own worktree so "Review this
    /// session's changes" lands on the right diff, not the project default.
    func openProjectPanel(_ tab: ProjectDetailView.ProjectTab, scopedTo session: Session?) {
        guard let session, let projectID = session.projectID else { return }
        if tab == .git {
            setProjectGitScope(session.worktree?.worktreePath ?? session.workingDirectory, for: projectID)
        }
        setProjectTab(tab, for: projectID)
        selection = .project(projectID)
    }

    func projectGitSubTab(for projectID: UUID) -> ProjectGitView.GitSubTab {
        projectGitSubTabs[projectID] ?? .changes
    }

    func setProjectGitSubTab(_ subTab: ProjectGitView.GitSubTab, for projectID: UUID) {
        projectGitSubTabs[projectID] = subTab
    }

    /// Opens the existing full Git overview at one exact sidebar commit.
    /// The sidebar is deliberately a compact navigator; commit inspection
    /// stays in the graph/detail workspace that already owns it.
    func openProjectCommit(
        _ commit: GitCommit,
        branch: String,
        scopedTo session: Session,
        gitService: any GitServiceProtocol
    ) {
        guard let projectID = session.projectID else { return }
        let repoPath = (session.worktree?.worktreePath ?? session.workingDirectory).standardizedFileURL
        setProjectGitScope(repoPath, for: projectID)
        setProjectGitSubTab(.commits, for: projectID)

        let graphViewModel = projectGraphViewModel(for: repoPath, gitService: gitService)
        graphViewModel.selectedBranchFilter = branch
        graphViewModel.selectedSHA = commit.sha

        setProjectTab(.git, for: projectID)
        selection = .project(projectID)
    }

    /// File browser models outlive the conditional project/session surfaces
    /// that display them. Reusing one model per workspace preserves its loaded
    /// tree, selected file, editor contents, and save metadata across facet
    /// switches.
    func fileBrowserViewModel(for rootURL: URL) -> FileBrowserViewModel {
        let normalizedRoot = rootURL.standardizedFileURL
        if let existing = fileBrowserViewModels[normalizedRoot] {
            return existing
        }

        let viewModel = FileBrowserViewModel(root: normalizedRoot)
        fileBrowserViewModels[normalizedRoot] = viewModel
        return viewModel
    }

    /// Commit graph selection, filtering, search, and loaded history belong to
    /// the repository scope rather than to one short-lived presentation.
    func projectGraphViewModel(
        for rootURL: URL,
        gitService: any GitServiceProtocol
    ) -> ProjectGraphViewModel {
        let normalizedRoot = rootURL.standardizedFileURL
        if let existing = projectGraphViewModels[normalizedRoot] {
            return existing
        }

        let viewModel = ProjectGraphViewModel(repoPath: normalizedRoot, gitService: gitService)
        projectGraphViewModels[normalizedRoot] = viewModel
        return viewModel
    }

    /// Keyed by the session's repo path (worktree or working directory), not
    /// session identity — `ProjectGitView` re-derives a session for the
    /// selected scope on every render (`matchingSession`/`dummySession`), and
    /// a `DiffPanelView` built fresh from one of those each time would reset
    /// its view model — losing in-flight staging/commit state — on every
    /// unrelated re-render of the surrounding view.
    func diffPanelViewModel(
        for session: Session,
        gitService: any GitServiceProtocol,
        ghService: (any GhServiceProtocol)?,
        commitEnvironment: (@MainActor () -> [String: String])? = nil
    ) -> DiffPanelViewModel {
        let repoPath = (session.worktree?.worktreePath ?? session.workingDirectory).standardizedFileURL
        if let existing = diffPanelViewModels[repoPath] {
            existing.commitEnvironment = commitEnvironment
            return existing
        }

        let viewModel = DiffPanelViewModel(
            session: session,
            gitService: gitService,
            ghService: ghService,
            commitEnvironment: commitEnvironment
        )
        diffPanelViewModels[repoPath] = viewModel
        return viewModel
    }

    /// Like the project Git models above, sidebar state is keyed by checkout
    /// path so hiding and reopening the inspector preserves the selected tab,
    /// branch filter, staging state, and commit draft.
    func sessionGitSidebarViewModel(
        for session: Session,
        gitService: any GitServiceProtocol,
        commitEnvironment: (@MainActor () -> [String: String])? = nil
    ) -> SessionGitSidebarViewModel {
        let repoPath = (session.worktree?.worktreePath ?? session.workingDirectory).standardizedFileURL
        if let existing = sessionGitSidebarViewModels[repoPath] {
            existing.commitEnvironment = commitEnvironment
            return existing
        }

        let viewModel = SessionGitSidebarViewModel(
            session: session,
            gitService: gitService,
            commitEnvironment: commitEnvironment
        )
        sessionGitSidebarViewModels[repoPath] = viewModel
        return viewModel
    }

    nonisolated init() {}
}

private struct WorkspaceNavigatorKey: EnvironmentKey {
    static let defaultValue: WorkspaceNavigator = {
        WorkspaceNavigator()
    }()
}

extension EnvironmentValues {
    var workspaceNavigator: WorkspaceNavigator {
        get { self[WorkspaceNavigatorKey.self] }
        set { self[WorkspaceNavigatorKey.self] = newValue }
    }
}

enum SidebarItem: Hashable, Codable, Sendable {
    case overview
    case allSessions
    /// A standing question about the fleet — see `FleetSmartList`. Added after
    /// the other cases shipped; synthesized `Codable` keeps decoding persisted
    /// values of those unchanged.
    case smartList(FleetSmartList)
    case project(UUID)
    case session(UUID)

    var title: String {
        switch self {
        case .overview: return "Home"
        case .allSessions: return "All Sessions"
        case .smartList(let list): return list.title
        case .project: return "Project"
        case .session: return "Session"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "house"
        case .allSessions: return "square.stack.3d.up"
        case .smartList(let list): return list.systemImage
        case .project: return "folder.fill"
        case .session: return "terminal.fill"
        }
    }

    /// True for the destinations that render the session collection — the only
    /// ones where a presentation (Grid / Board / Focus) means anything.
    var isCollection: Bool {
        switch self {
        case .allSessions, .smartList: return true
        case .overview, .project, .session: return false
        }
    }
}

enum WorkspacePresentation: String, CaseIterable, Identifiable, Codable, Sendable {
    case grid
    case board
    case focus

    var id: Self { self }

    var title: String {
        switch self {
        case .grid: return "Grid"
        case .board: return "Board"
        case .focus: return "Focus"
        }
    }

    var systemImage: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .board: return "rectangle.split.3x1"
        case .focus: return "macwindow"
        }
    }
}

enum WorkspaceSheet: Identifiable, Equatable, Codable, Sendable {
    /// `opensIssuePicker` opens the launcher with its issue picker showing;
    /// `issueNumber` opens it with that issue already linked. Optional so
    /// sheets encoded before they existed still decode.
    case createSession(initialGoal: String? = nil, projectID: UUID? = nil, opensIssuePicker: Bool? = nil, issueNumber: Int? = nil)
    case commandPalette
    case shortcuts
    case restore
    case deleteSession(UUID)

    static var createSession: WorkspaceSheet { .createSession() }

    var id: String {
        switch self {
        case .createSession(let goal, let projectID, let opensIssuePicker, let issueNumber):
            "create-session-\(goal ?? "")-\(projectID?.uuidString ?? "")-\(opensIssuePicker == true ? "issue" : "")-\(issueNumber.map(String.init) ?? "")"
        case .commandPalette: "command-palette"
        case .shortcuts: "shortcuts"
        case .restore: "restore"
        case .deleteSession(let id): "delete-session-\(id)"
        }
    }
}
