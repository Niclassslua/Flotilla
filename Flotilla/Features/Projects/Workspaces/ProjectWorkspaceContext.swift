import SwiftUI
import SessionKit
import GitKit
import DesignSystem
import SettingsKit

/// Everything the project workspace needs, bundled so the parameter list stays
/// in one place. `DetailColumn` builds one for `StreamProjectWorkspace` and
/// for every rail tool.
struct ProjectWorkspaceContext {
    let project: Project
    let sessions: [Session]
    let store: AppStore
    let terminalManager: TerminalManager
    let activityStore: SessionActivityStore
    let openSession: (UUID) -> Void
    let openCodeSubscription: OpenCodeSubscription
    let highlightUnseenCommits: Bool
    let createWorktreeByDefault: Bool
    let fetchBeforeCreatingWorktree: Bool
    let defaultAgent: AgentKind
}

/// Renders a rail tool. Git / Issues / Files / Skills / Rules go through this
/// single switch so their heavy view models stay shared.
struct ProjectSurfaceHost: View {
    @Environment(\.workspaceNavigator) private var navigator
    let tool: ProjectTool
    let context: ProjectWorkspaceContext

    var body: some View {
        switch tool {
        case .git:
            ProjectGitView(
                project: context.project,
                sessions: context.sessions,
                store: context.store,
                highlightUnseenCommits: context.highlightUnseenCommits
            )
            .id(context.project.id)
        case .issues:
            ProjectIssuesView(project: context.project, store: context.store, openSession: context.openSession)
                .id(context.project.id)
        case .files:
            FileBrowserView(viewModel: navigator.fileBrowserViewModel(for: context.project.rootPath))
        case .skills:
            ProjectSkillsView(project: context.project, store: context.store)
        case .rules:
            ProjectRulesView(project: context.project, store: context.store)
        }
    }
}
