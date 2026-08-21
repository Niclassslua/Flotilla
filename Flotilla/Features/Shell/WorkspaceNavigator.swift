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
            switch selection {
            case .overview, .project:
                lastOverviewSelection = selection
            case .allSessions, .session:
                break
            }
        }
    }
    var presentation: WorkspacePresentation = ProcessInfo.processInfo.environment["UI_TESTING"] == "1" ? .focus : .grid
    var presentedSheet: WorkspaceSheet?
    var columnVisibility: NavigationSplitViewVisibility = .all
    var searchText = ""
    private(set) var lastOverviewSelection: SidebarItem = .overview
    private var projectTabs: [UUID: ProjectDetailView.ProjectTab] = [:]
    private var projectGitScopes: [UUID: URL] = [:]
    private var projectGitSubTabs: [UUID: ProjectGitView.GitSubTab] = [:]
    @ObservationIgnored private var fileBrowserViewModels: [URL: FileBrowserViewModel] = [:]
    @ObservationIgnored private var projectGraphViewModels: [URL: ProjectGraphViewModel] = [:]

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

    var sessionLens: SessionLens = .terminal

    /// Returns to the place the user last occupied in the Overview facet.
    /// Sessions are a sibling workspace, so visiting them must not flatten a
    /// project's internal navigation back to its dashboard.
    func restoreOverviewSelection() {
        selection = lastOverviewSelection
    }

    /// Intentionally leaves a project drill-down for the overview dashboard.
    func showOverviewDashboard() {
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

    func projectGitSubTab(for projectID: UUID) -> ProjectGitView.GitSubTab {
        projectGitSubTabs[projectID] ?? .changes
    }

    func setProjectGitSubTab(_ subTab: ProjectGitView.GitSubTab, for projectID: UUID) {
        projectGitSubTabs[projectID] = subTab
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
    case project(UUID)
    case session(UUID)

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .allSessions: return "All Sessions"
        case .project: return "Project"
        case .session: return "Session"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "house"
        case .allSessions: return "terminal"
        case .project: return "folder.fill"
        case .session: return "terminal.fill"
        }
    }
}

enum WorkspacePresentation: String, CaseIterable, Identifiable, Codable, Sendable {
    case grid
    case board
    case list
    case focus

    var id: Self { self }

    var title: String {
        switch self {
        case .grid: return "Grid"
        case .board: return "Board"
        case .list: return "List"
        case .focus: return "Focus"
        }
    }

    var systemImage: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .board: return "square.grid.2x2.fill"
        case .list: return "list.bullet"
        case .focus: return "macwindow"
        }
    }
}

enum WorkspaceSheet: Identifiable, Equatable, Codable, Sendable {
    case createSession(initialGoal: String? = nil, projectID: UUID? = nil)
    case commandPalette
    case shortcuts
    case restore
    case deleteSession(UUID)

    static var createSession: WorkspaceSheet { .createSession() }

    var id: String {
        switch self {
        case .createSession(let goal, let projectID):
            "create-session-\(goal ?? "")-\(projectID?.uuidString ?? "")"
        case .commandPalette: "command-palette"
        case .shortcuts: "shortcuts"
        case .restore: "restore"
        case .deleteSession(let id): "delete-session-\(id)"
        }
    }
}

enum SessionLens: String, CaseIterable, Identifiable, Codable, Sendable {
    case terminal
    case changes
    case files
    case instructions

    var id: Self { self }

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .changes: return "Changes"
        case .files: return "Files"
        case .instructions: return "Instructions"
        }
    }

    var systemImage: String {
        switch self {
        case .terminal: return "terminal"
        case .changes: return "arrow.triangle.branch"
        case .files: return "folder"
        case .instructions: return "doc.badge.gearshape"
        }
    }
}
