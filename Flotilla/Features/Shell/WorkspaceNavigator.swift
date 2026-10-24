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
            case .session(let id):
                focusedSessionID = id
            case .allSessions, .smartList, .projectTool:
                break
            }
            // Tool destinations are not List tags, and the rail already marks
            // the active tool. Mirroring the project row instead would fold
            // back through `FlotillaShell` as a click on that row and bounce
            // the tool to the overview — and leave the row too lit to click.
            switch selection {
            case .overview, .projectTool:
                sidebarSelection = []
            case .allSessions, .smartList, .project, .session:
                sidebarSelection = [selection]
            }
            recordHistory(from: oldValue)
        }
    }
    /// Session Focus shows while the navigator stays on All Sessions / a smart
    /// list. Selection stays on the collection; this is what Focus renders.
    private(set) var focusedSessionID: UUID?
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
    private var projectGitScopes: [UUID: URL] = [:]
    private var projectGitSubTabs: [UUID: ProjectGitView.GitSubTab] = [:]
    @ObservationIgnored private var fileBrowserViewModels: [URL: FileBrowserViewModel] = [:]
    @ObservationIgnored private var projectGraphViewModels: [URL: ProjectGraphViewModel] = [:]
    @ObservationIgnored private var diffPanelViewModels: [URL: DiffPanelViewModel] = [:]
    @ObservationIgnored private var sessionGitSidebarViewModels: [URL: SessionGitSidebarViewModel] = [:]

    // Legacy compatibility — bridges store selection IDs and navigator selection.
    var selectedSessionID: UUID? {
        get {
            switch selection {
            case .session(let id): return id
            case .allSessions, .smartList: return focusedSessionID
            case .overview, .project, .projectTool: return nil
            }
        }
        set {
            if let newValue {
                focusedSessionID = newValue
                // Collections keep their own selection; Focus reads focusedSessionID.
                if !selection.isCollection {
                    selection = .session(newValue)
                }
            } else {
                focusedSessionID = nil
                if case .session = selection {
                    selection = .allSessions
                }
            }
        }
    }

    var selectedProjectID: UUID? {
        get {
            switch selection {
            case .project(let id), .projectTool(let id, _): return id
            default: return nil
            }
        }
        set {
            if let newValue {
                selection = .project(newValue)
            } else if selectedProjectID != nil {
                selection = .overview
            }
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
    /// `nil` until the shell primes them — unprimed means "accept any ID" so
    /// unit tests and early launch don't treat every destination as dead.
    private var knownSessionIDs: Set<UUID>?
    private var knownProjectIDs: Set<UUID>?

    private static let historyLimit = 50

    var canGoBack: Bool { backStack.contains(where: isValidDestination) }
    var canGoForward: Bool { forwardStack.contains(where: isValidDestination) }

    private func recordHistory(from previous: SidebarItem) {
        guard !isNavigatingHistory else { return }
        backStack.append(previous)
        if backStack.count > Self.historyLimit { backStack.removeFirst() }
        // A fresh navigation abandons any forward branch, the same way a
        // browser does.
        forwardStack.removeAll()
    }

    func goBack() {
        while let destination = backStack.popLast() {
            guard isValidDestination(destination) else { continue }
            isNavigatingHistory = true
            forwardStack.append(selection)
            selection = destination
            isNavigatingHistory = false
            return
        }
    }

    func goForward() {
        while let destination = forwardStack.popLast() {
            guard isValidDestination(destination) else { continue }
            isNavigatingHistory = true
            backStack.append(selection)
            selection = destination
            isNavigatingHistory = false
            return
        }
    }

    /// Drops history entries (and the current selection) that point at sessions
    /// or projects that no longer exist.
    func pruneNavigation(sessions sessionIDs: Set<UUID>, projects projectIDs: Set<UUID>) {
        knownSessionIDs = sessionIDs
        knownProjectIDs = projectIDs
        backStack.removeAll { !isValidDestination($0) }
        forwardStack.removeAll { !isValidDestination($0) }
        guard !isValidDestination(selection) else { return }
        isNavigatingHistory = true
        switch selection {
        case .session:
            focusedSessionID = nil
            selection = .allSessions
        case .project, .projectTool:
            selection = .overview
        case .overview, .allSessions, .smartList:
            break
        }
        isNavigatingHistory = false
    }

    private func isValidDestination(_ item: SidebarItem) -> Bool {
        switch item {
        case .overview, .allSessions, .smartList:
            return true
        case .session(let id):
            guard let known = knownSessionIDs else { return true }
            return known.contains(id)
        case .project(let id), .projectTool(let id, _):
            guard let known = knownProjectIDs else { return true }
            return known.contains(id)
        }
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
        case .project(let id), .projectTool(let id, _): SessionScope(group: .project(id), smartList: nil)
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

    /// Clears a tool/overview destination that still points at a deleted project.
    func pruneProjectDestinations(against projectIDs: Set<UUID>) {
        switch selection {
        case .project(let id), .projectTool(let id, _):
            if !projectIDs.contains(id) { selection = .overview }
        default:
            break
        }
        projectGitScopes = projectGitScopes.filter { projectIDs.contains($0.key) }
        projectGitSubTabs = projectGitSubTabs.filter { projectIDs.contains($0.key) }
        if case .project(let id) = lastOverviewSelection, !projectIDs.contains(id) {
            lastOverviewSelection = .overview
        }
    }

    /// Unambiguous project for the tool rail, palette, and shortcuts.
    /// Home, General, and all-projects collections return `nil` — never the
    /// previously selected project. A one-project Grid/Board group enables tools.
    func railProjectID(sessions: [Session]) -> UUID? {
        switch selection {
        case .project(let id), .projectTool(let id, _):
            return id
        case .session(let id):
            return sessions.first(where: { $0.id == id })?.projectID
        case .allSessions, .smartList:
            // One-project Grid/Board filter enables tools; focusing a tile
            // must not silently change this collection's project context.
            if case .project(let id) = sessionGroup { return id }
            return nil
        case .overview:
            return nil
        }
    }

    /// Tool highlighted in the rail. Nil on overview and terminals.
    var activeRailTool: ProjectTool? {
        if case .projectTool(_, let tool) = selection { return tool }
        return nil
    }

    /// Opens a tool for the rail's project context; inert without one. Shared by
    /// the rail, the Workspace menu, and the command palette.
    func openRailTool(_ tool: ProjectTool, sessions: [Session]) {
        guard let projectID = railProjectID(sessions: sessions) else { return }
        openProjectTool(tool, projectID: projectID)
    }

    /// Opens a project tool in the main content column without filtering the
    /// session list. Git lands on the project history (Commits) surface and
    /// does not reset an existing branch/commit selection.
    func openProjectTool(_ tool: ProjectTool, projectID: UUID) {
        // First visit to Git lands on history (Commits). Later visits keep
        // whatever sub-tab the user left on so tool state survives navigation.
        if tool == .git, projectGitSubTabs[projectID] == nil {
            setProjectGitSubTab(.commits, for: projectID)
        }
        selection = .projectTool(projectID, tool)
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

    func projectGitScope(for projectID: UUID) -> URL? {
        projectGitScopes[projectID]
    }

    func setProjectGitScope(_ scope: URL?, for projectID: UUID) {
        projectGitScopes[projectID] = scope
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

        openProjectTool(.git, projectID: projectID)
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
            existing.session = session
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
    /// A project tool in the main content column (issue #7). Distinct from
    /// `.project`, which is always the overview.
    case projectTool(UUID, ProjectTool)
    case session(UUID)

    var title: String {
        switch self {
        case .overview: return "Home"
        case .allSessions: return "All Sessions"
        case .smartList(let list): return list.title
        case .project: return "Project"
        case .projectTool(_, let tool): return tool.title
        case .session: return "Session"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "house"
        case .allSessions: return "square.stack.3d.up"
        case .smartList(let list): return list.systemImage
        case .project: return "folder.fill"
        case .projectTool(_, let tool): return tool.systemImage
        case .session: return "terminal.fill"
        }
    }

    /// True for the destinations that render the session collection — the only
    /// ones where a presentation (Grid / Board / Focus) means anything.
    var isCollection: Bool {
        switch self {
        case .allSessions, .smartList: return true
        case .overview, .project, .projectTool, .session: return false
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
    case onboarding

    static var createSession: WorkspaceSheet { .createSession() }

    var id: String {
        switch self {
        case .createSession(let goal, let projectID, let opensIssuePicker, let issueNumber):
            "create-session-\(goal ?? "")-\(projectID?.uuidString ?? "")-\(opensIssuePicker == true ? "issue" : "")-\(issueNumber.map(String.init) ?? "")"
        case .commandPalette: "command-palette"
        case .shortcuts: "shortcuts"
        case .restore: "restore"
        case .deleteSession(let id): "delete-session-\(id)"
        case .onboarding: "onboarding"
        }
    }
}
