import SwiftUI
import SessionKit
import GitKit
import DesignSystem
import SettingsKit

/// Entry point for a project workspace. It builds the shared
/// `ProjectWorkspaceContext` and hands it to `StreamProjectWorkspace`, which
/// draws the whole surface (activity feed + context column, with Git / Files /
/// Skills / Rules routed through underneath).
///
/// `ProjectTab` stays defined here: it is the canonical list of the five
/// surfaces, shared by `WorkspaceNavigator` and the workspace view.
struct ProjectDetailView: View {
    let project: Project
    let sessions: [Session]
    @Bindable var store: AppStore
    let terminalManager: TerminalManager
    let activityStore: SessionActivityStore
    let openSession: (UUID) -> Void
    let openCodeSubscription: OpenCodeSubscription
    let highlightUnseenCommits: Bool
    let createWorktreeByDefault: Bool
    let fetchBeforeCreatingWorktree: Bool
    let defaultAgent: AgentKind

    /// The five surfaces a project workspace provides.
    enum ProjectTab: String, CaseIterable, Identifiable, Codable, Sendable {
        case overview, git, files, skills, rules

        var id: Self { self }

        var title: String {
            switch self {
            case .overview: return "Overview"
            case .git:      return "Git"
            case .files:    return "Files"
            case .skills:   return "Skills"
            case .rules:    return "Rules"
            }
        }

        var systemImage: String {
            switch self {
            case .overview: return "square.grid.2x2"
            case .git:      return "arrow.triangle.branch"
            case .files:    return "folder"
            case .skills:   return "sparkles"
            case .rules:    return "doc.badge.gearshape"
            }
        }
    }

    private var context: ProjectWorkspaceContext {
        ProjectWorkspaceContext(
            project: project,
            sessions: sessions,
            store: store,
            terminalManager: terminalManager,
            activityStore: activityStore,
            openSession: openSession,
            openCodeSubscription: openCodeSubscription,
            highlightUnseenCommits: highlightUnseenCommits,
            createWorktreeByDefault: createWorktreeByDefault,
            fetchBeforeCreatingWorktree: fetchBeforeCreatingWorktree,
            defaultAgent: defaultAgent
        )
    }

    var body: some View {
        StreamProjectWorkspace(context: context)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
