import SwiftUI
import AppKit
import SessionKit
import GitKit
import DesignSystem

/// Git workspace for a project, providing Changes (diff inspection & commit),
/// Commits (linear timeline & details), and Graph (visual commit DAG) sub-tabs,
/// with a repository/worktree scope picker.
struct ProjectGitView: View {
    let project: Project
    let sessions: [Session]
    @Bindable var store: AppStore
    let highlightUnseenCommits: Bool

    @State private var selectedSubTab: GitSubTab = .changes
    @State private var selectedScopeURL: URL
    @State private var worktrees: [GitWorktree] = []

    enum GitSubTab: String, CaseIterable, Identifiable {
        case changes, commits, graph

        var id: Self { self }

        var title: String {
            switch self {
            case .changes: return "Changes"
            case .commits: return "Commits"
            case .graph:   return "Graph"
            }
        }

        var systemImage: String {
            switch self {
            case .changes: return "doc.text.magnifyingglass"
            case .commits: return "clock.arrow.circlepath"
            case .graph:   return "point.3.connected.trianglepath.dotted"
            }
        }
    }

    init(
        project: Project,
        sessions: [Session],
        store: AppStore,
        highlightUnseenCommits: Bool,
        initialScopeURL: URL? = nil
    ) {
        self.project = project
        self.sessions = sessions
        self.store = store
        self.highlightUnseenCommits = highlightUnseenCommits
        self._selectedScopeURL = State(initialValue: initialScopeURL ?? project.rootPath)
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
                    ProjectHistoryView(
                        repoPath: selectedScopeURL,
                        gitService: store.gitService,
                        sessions: sessions,
                        highlightUnseenCommits: highlightUnseenCommits
                    )
                    .id(selectedScopeURL)
                case .graph:
                    ProjectGraphView(
                        repoPath: selectedScopeURL,
                        gitService: store.gitService,
                        sessions: sessions
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
            withAnimation(FlotillaMotion.fast.curve) { selectedSubTab = tab }
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
                selectedScopeURL = project.rootPath
            } label: {
                Label("Main Checkout (\(project.name))", systemImage: selectedScopeURL == project.rootPath ? "checkmark" : "")
            }

            if !worktrees.filter({ !$0.isMainWorktree }).isEmpty {
                Divider()
                ForEach(worktrees.filter({ !$0.isMainWorktree }), id: \.path) { wt in
                    Button {
                        selectedScopeURL = wt.path
                    } label: {
                        Label(wt.branch, systemImage: selectedScopeURL == wt.path ? "checkmark" : "")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selectedScopeURL == project.rootPath ? "house.fill" : "arrow.triangle.branch")
                    .font(.system(size: 10))
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

    // MARK: - Changes Pane

    private var changesPane: some View {
        let targetSession = matchingSession(for: selectedScopeURL) ?? dummySession(for: selectedScopeURL)
        return DiffPanelView(
            session: targetSession,
            gitService: store.gitService,
            ghService: store.ghService
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
