import SwiftUI
import AppKit
import SessionKit
import GitKit
import DesignSystem

/// Git workspace for a project, providing Changes (diff inspection & commit)
/// and Commits (unified visual DAG graph, history, search & detail inspector),
/// with a repository/worktree scope picker.
struct ProjectGitView: View {
    @Environment(\.workspaceNavigator) private var navigator
    let project: Project
    let sessions: [Session]
    @Bindable var store: AppStore
    let highlightUnseenCommits: Bool

    @State private var worktrees: [GitWorktree] = []

    enum GitSubTab: String, CaseIterable, Identifiable, Codable, Sendable {
        case changes, commits

        var id: Self { self }

        var title: String {
            switch self {
            case .changes: return "Changes"
            case .commits: return "Commits"
            }
        }

        var systemImage: String {
            switch self {
            case .changes: return "doc.text.magnifyingglass"
            case .commits: return "point.3.connected.trianglepath.dotted"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            gitSubTabBar
            Divider()

            Group {
                switch selectedSubTab {
                case .changes:
                    changesPane
                        .id(selectedScopeURL)
                case .commits:
                    ProjectGraphView(
                        viewModel: navigator.projectGraphViewModel(
                            for: selectedScopeURL,
                            gitService: store.gitService
                        ),
                        sessions: sessions,
                        highlightUnseenCommits: highlightUnseenCommits
                    )
                    .id(selectedScopeURL)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: project.id) {
            await loadWorktrees()
        }
    }

    // MARK: - Sub-tab Bar & Scope Picker

    private var gitSubTabBar: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            scopePicker

            Divider().frame(height: 16)

            HStack(spacing: 0) {
                ForEach(GitSubTab.allCases) { tab in
                    subTabButton(tab)
                }
            }

            Spacer()
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .background(FlotillaColors.surface)
    }

    private func subTabButton(_ tab: GitSubTab) -> some View {
        let isActive = selectedSubTab == tab
        return Button {
            withAnimation(FlotillaMotion.fast.curve) {
                navigator.setProjectGitSubTab(tab, for: project.id)
            }
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: tab.systemImage)
                        .font(.system(size: 11))
                    Text(tab.title)
                        .font(FlotillaTypography.caption.weight(isActive ? .semibold : .regular))
                }
                .foregroundStyle(isActive ? FlotillaColors.textPrimary : FlotillaColors.textTertiary)
                .padding(.top, 6)

                Rectangle()
                    .fill(isActive ? FlotillaColors.accent : .clear)
                    .frame(height: 2)
            }
            .padding(.horizontal, FlotillaSpacing.small + 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ProjectGit.SubTab-\(tab.title)")
    }

    private var scopePicker: some View {
        Menu {
            Button {
                navigator.setProjectGitScope(project.rootPath, for: project.id)
            } label: {
                Label("Main Checkout (\(project.name))", systemImage: selectedScopeURL == project.rootPath ? "checkmark" : "")
            }

            if !worktrees.filter({ !$0.isMainWorktree }).isEmpty {
                Divider()
                ForEach(worktrees.filter({ !$0.isMainWorktree }), id: \.path) { wt in
                    Button {
                        navigator.setProjectGitScope(wt.path, for: project.id)
                    } label: {
                        Label(wt.branch, systemImage: selectedScopeURL == wt.path ? "checkmark" : "")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if selectedScopeURL == project.rootPath {
                    Image(systemName: "house.fill")
                        .font(.system(size: 10))
                } else {
                    GitBranchIcon(size: 10)
                }
                Text(currentScopeLabel)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(FlotillaColors.surfaceElevated, in: Capsule())
            .foregroundStyle(FlotillaColors.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("ProjectGit.ScopePicker")
    }

    private var currentScopeLabel: String {
        if selectedScopeURL == project.rootPath {
            return "Main (\(project.name))"
        }
        if let matching = worktrees.first(where: { $0.path.standardizedFileURL == selectedScopeURL.standardizedFileURL }) {
            return matching.branch
        }
        return selectedScopeURL.lastPathComponent
    }

    private var selectedSubTab: GitSubTab {
        navigator.projectGitSubTab(for: project.id)
    }

    private var selectedScopeURL: URL {
        navigator.projectGitScope(for: project.id) ?? project.rootPath
    }

    // MARK: - Changes Pane

    private var changesPane: some View {
        let targetSession = matchingSession(for: selectedScopeURL) ?? dummySession(for: selectedScopeURL)
        return DiffPanelView(
            viewModel: navigator.diffPanelViewModel(
                for: targetSession,
                gitService: store.gitService,
                ghService: store.ghService
            )
        )
    }

    // MARK: - Helpers

    private func matchingSession(for url: URL) -> Session? {
        sessions.first { session in
            if let worktree = session.worktree {
                return worktree.worktreePath.standardizedFileURL == url.standardizedFileURL
            }
            return session.workingDirectory.standardizedFileURL == url.standardizedFileURL
        }
    }

    private func dummySession(for url: URL) -> Session {
        let branchName = worktrees.first(where: { $0.path.standardizedFileURL == url.standardizedFileURL })?.branch ?? url.lastPathComponent
        return Session(
            title: branchName,
            goal: "Git Scope: \(branchName)",
            agent: .claudeCode,
            projectID: project.id,
            workingDirectory: url
        )
    }

    private func loadWorktrees() async {
        if let list = try? await store.gitService.listWorktrees(at: project.rootPath) {
            worktrees = list
        }
    }
}
