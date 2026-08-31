import SwiftUI
import AppKit
import SessionKit
import GitKit
import DesignSystem
import SettingsKit

/// Focused project view displaying repository status, Worktree Matrix, diff inspection, and project rules.
struct ProjectDetailView: View {
    @Environment(\.workspaceNavigator) private var navigator
    let project: Project
    let sessions: [Session]
    @Bindable var store: AppStore
    let terminalManager: TerminalManager
    let openSession: (UUID) -> Void
    let openCodeSubscription: OpenCodeSubscription
    let highlightUnseenCommits: Bool
    let createWorktreeByDefault: Bool
    let fetchBeforeCreatingWorktree: Bool
    let defaultAgent: AgentKind

    @State private var currentBranch: String?
    @State private var projectDiffStat: GitDiffStat?
    @State private var isShowingCreateSessionSheet = false

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

    var body: some View {
        VStack(spacing: 0) {
            projectHeader
            Divider()
            modeTabs
            Divider()

            Group {
                switch selectedTab {
                case .overview:
                    ProjectOverviewView(
                        project: project,
                        sessions: sessions,
                        store: store,
                        openSession: openSession,
                        onOpenInGit: { wt in
                            navigator.setProjectGitScope(wt.path, for: project.id)
                            withAnimation(FlotillaMotion.fast.curve) {
                                navigator.setProjectTab(.git, for: project.id)
                            }
                        }
                    )
                case .git:
                    ProjectGitView(
                        project: project,
                        sessions: sessions,
                        store: store,
                        highlightUnseenCommits: highlightUnseenCommits
                    )
                    .id(project.id)
                case .files:
                    FileBrowserView(viewModel: navigator.fileBrowserViewModel(for: project.rootPath))
                case .skills:
                    ProjectSkillsView(project: project, store: store)
                case .rules:
                    ProjectRulesView(project: project, store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: project.id) {
            if let branch = try? await store.gitService.currentBranch(at: project.rootPath) {
                currentBranch = branch
            }
            if let stat = try? await store.gitService.diffStat(at: project.rootPath) {
                projectDiffStat = stat
            }
        }
        .sheet(isPresented: $isShowingCreateSessionSheet) {
            CreateSessionView(
                store: store,
                createWorktreeByDefault: createWorktreeByDefault,
                fetchBeforeCreatingWorktree: fetchBeforeCreatingWorktree,
                initialProject: project,
                didCreateSession: openSession,
                openCodeSubscription: openCodeSubscription,
                defaultAgent: defaultAgent
            )
        }
    }

    /// A slim underline strip rather than a segmented picker: this switches
    /// the whole workspace, and native control chrome would break the
    /// continuous-surface feel the rest of the app keeps.
    private var modeTabs: some View {
        HStack(spacing: 0) {
            ForEach(ProjectTab.allCases) { candidate in
                modeTab(candidate)
            }
            Spacer()
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .background(FlotillaColors.surface)
    }

    private func modeTab(_ candidate: ProjectTab) -> some View {
        let isActive = selectedTab == candidate
        return Button {
            withAnimation(FlotillaMotion.fast.curve) {
                navigator.setProjectTab(candidate, for: project.id)
            }
        } label: {
            VStack(spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: candidate.systemImage)
                        .font(.system(size: FlotillaIconSize.small))
                    Text(candidate.title)
                        .font(FlotillaTypography.caption.weight(isActive ? .semibold : .regular))
                }
                .foregroundStyle(isActive ? FlotillaColors.textPrimary : FlotillaColors.textTertiary)
                .padding(.top, FlotillaSpacing.small)

                Rectangle()
                    .fill(isActive ? FlotillaColors.accent : .clear)
                    .frame(height: 2)
            }
            .padding(.horizontal, FlotillaSpacing.medium)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ProjectDetail.ModeTab-\(candidate.title)")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private var selectedTab: ProjectTab {
        navigator.projectTab(for: project.id)
    }

    private var projectHeader: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
            // No in-page back control. The project used to be reachable only
            // by drilling through Home, so it had to offer its own way out;
            // now it is a navigator row like any other, and the toolbar's
            // Back (⌘[) returns you to wherever you actually came from —
            // which is often a session, not Home.
            HStack(alignment: .center, spacing: FlotillaSpacing.medium) {
                ProjectMark(title: project.name, tint: ProjectMark.tint(for: project))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: FlotillaSpacing.small) {
                        Text(project.name)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(FlotillaColors.textPrimary)

                        if let branch = currentBranch {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: FlotillaIconSize.small))
                                Text(branch)
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(FlotillaColors.surfaceElevated, in: Capsule())
                            .foregroundStyle(FlotillaColors.textSecondary)
                        }

                        if let stat = projectDiffStat, !stat.isEmpty {
                            DiffStatBadge(stat: stat)
                        }
                    }

                    Text(project.rootPath.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                HStack(spacing: FlotillaSpacing.small) {
                    Button {
                        isShowingCreateSessionSheet = true
                    } label: {
                        Label("New Session", systemImage: "plus")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FlotillaColors.accent)
                    .accessibilityIdentifier("ProjectDetail.NewSessionButton")
                }
            }
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.medium)
        .background(FlotillaColors.surface)
    }
}
