import SwiftUI
import AppKit
import SessionKit
import GitKit
import DesignSystem

/// High-density interactive Git Worktree & Branch Matrix (Design 4).
/// Displays all active worktrees, attached agent sessions, live diff stats,
/// and provides 1-click Prune, Merge, and Diff Inspection capabilities.
struct ProjectWorktreeMatrixView: View {
    let project: Project
    let sessions: [Session]
    @Bindable var store: AppStore
    let openSession: (UUID) -> Void

    @State private var worktrees: [GitWorktree] = []
    @State private var isLoading = false
    @State private var selectedWorktree: GitWorktree?
    @State private var worktreeToPrune: GitWorktree?
    @State private var showPruneConfirmation = false
    @State private var isPruning = false
    @State private var errorMessage: String?

    var body: some View {
        HSplitView {
            worktreeTableSection
                .frame(minWidth: 420, idealWidth: 540)
            
            diffInspectorSection
                .frame(minWidth: 360, idealWidth: 460)
        }
        .task(id: project.id) {
            await loadWorktrees()
        }
        .alert("Prune Worktree", isPresented: $showPruneConfirmation) {
            Button("Cancel", role: .cancel) {
                worktreeToPrune = nil
            }
            Button("Prune and Delete Branch", role: .destructive) {
                if let wt = worktreeToPrune {
                    Task { await pruneWorktree(wt, deleteBranch: true) }
                }
            }
            Button("Prune Directory Only", role: .none) {
                if let wt = worktreeToPrune {
                    Task { await pruneWorktree(wt, deleteBranch: false) }
                }
            }
        } message: {
            if let wt = worktreeToPrune {
                Text("Are you sure you want to remove the worktree for branch '\(wt.branch)' at \(wt.path.path)? Any uncommitted changes in this worktree will be lost.")
            }
        }
        .alert("Worktree Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Worktree Table Section

    private var worktreeTableSection: some View {
        VStack(spacing: 0) {
            tableHeader
            Divider()

            if isLoading && worktrees.isEmpty {
                ProgressView("Scanning worktrees…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if worktrees.isEmpty {
                ContentUnavailableView(
                    "No Worktrees",
                    systemImage: "arrow.triangle.branch",
                    description: Text("No isolated worktrees found. Launch a session with 'New worktree' enabled to create one.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedWorktree) {
                    ForEach(worktrees, id: \.path) { wt in
                        worktreeRow(for: wt)
                            .tag(wt)
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                            .listRowBackground(
                                selectedWorktree?.path == wt.path
                                    ? FlotillaColors.surfaceElevated
                                    : Color.clear
                            )
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(FlotillaColors.surface)
    }

    private var tableHeader: some View {
        HStack(spacing: FlotillaSpacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text("WORKTREES & BRANCHES")
                    .font(FlotillaTypography.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(FlotillaColors.accent)
                Text("\(worktrees.count) total (\(worktrees.filter { !$0.isMainWorktree }.count) isolated)")
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textSecondary)
            }

            Spacer()

            Button {
                Task { await loadWorktrees() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh worktrees")
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
        .background(FlotillaColors.surfaceElevated)
    }

    private func worktreeRow(for wt: GitWorktree) -> some View {
        let session = matchingSession(for: wt)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: FlotillaSpacing.small) {
                Image(systemName: wt.isMainWorktree ? "house.fill" : "arrow.triangle.branch")
                    .font(.system(size: FlotillaIconSize.medium))
                    .foregroundStyle(wt.isMainWorktree ? FlotillaColors.accent : FlotillaColors.textSecondary)

                Text(wt.branch)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textPrimary)

                if wt.isMainWorktree {
                    Text("Main Checkout")
                        .font(FlotillaTypography.caption2.weight(.medium))
                        .foregroundStyle(FlotillaColors.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(FlotillaColors.accent.opacity(0.12), in: Capsule())
                }

                Spacer()

                if let session {
                    StatusBadge(session.status, size: .micro, showLabel: false)
                    Text(session.agent.displayName)
                        .font(FlotillaTypography.caption)
                        .foregroundStyle(FlotillaColors.textSecondary)
                }

                SessionDiffStatView(
                    session: session ?? dummySession(for: wt),
                    diffStatStore: store.diffStatStore
                )
            }

            Text(wt.path.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(FlotillaColors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let session {
                Text(session.goal)
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .lineLimit(1)
            }

            HStack(spacing: FlotillaSpacing.small) {
                if let session {
                    Button {
                        openSession(session.id)
                    } label: {
                        Label("Terminal", systemImage: "terminal")
                            .font(FlotillaTypography.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button {
                    selectedWorktree = wt
                } label: {
                    Label("Inspect Diff", systemImage: "doc.text.magnifyingglass")
                        .font(FlotillaTypography.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([wt.path])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: FlotillaIconSize.small))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reveal in Finder")

                Spacer()

                if !wt.isMainWorktree {
                    Button(role: .destructive) {
                        worktreeToPrune = wt
                        showPruneConfirmation = true
                    } label: {
                        Label("Prune", systemImage: "trash")
                            .font(FlotillaTypography.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(FlotillaColors.statusCrashed)
                    .help("Remove worktree directory and branch")
                    .accessibilityIdentifier("Worktree.PruneButton-\(wt.branch)")
                }
            }
            .padding(.top, 2)
        }
        .padding(FlotillaSpacing.small)
        .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.card)
                .strokeBorder(
                    selectedWorktree?.path == wt.path
                        ? FlotillaColors.accent.opacity(0.4)
                        : FlotillaColors.separator.opacity(0.5)
                )
        }
    }

    // MARK: - Diff Inspector Section

    private var diffInspectorSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text(selectedWorktree != nil ? "DIFF: \(selectedWorktree!.branch)" : "DIFF INSPECTOR")
                    .font(FlotillaTypography.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(FlotillaColors.accent)
                Spacer()
                if let wt = selectedWorktree {
                    Text(wt.path.lastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
            }
            .padding(.horizontal, FlotillaSpacing.medium)
            .padding(.vertical, FlotillaSpacing.small)
            .background(FlotillaColors.surfaceElevated)

            Divider()

            if let targetWorktree = selectedWorktree ?? worktrees.first {
                let targetSession = matchingSession(for: targetWorktree) ?? dummySession(for: targetWorktree)
                DiffPanelView(session: targetSession, gitService: store.gitService, ghService: store.ghService)
                    .id(targetWorktree.path)
            } else {
                ContentUnavailableView(
                    "No Worktree Selected",
                    systemImage: "arrow.triangle.branch",
                    description: Text("Select a worktree to inspect its live unstaged and staged git changes.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(FlotillaColors.canvas)
    }

    // MARK: - Helpers

    private func matchingSession(for wt: GitWorktree) -> Session? {
        sessions.first { session in
            if let worktree = session.worktree {
                return worktree.worktreePath.standardizedFileURL == wt.path.standardizedFileURL
            }
            if wt.isMainWorktree {
                return session.workingDirectory.standardizedFileURL == wt.path.standardizedFileURL
            }
            return false
        }
    }

    private func dummySession(for wt: GitWorktree) -> Session {
        Session(
            title: wt.branch,
            goal: "Worktree: \(wt.branch)",
            agent: .claudeCode,
            projectID: project.id,
            workingDirectory: wt.path
        )
    }

    private func loadWorktrees() async {
        isLoading = true
        defer { isLoading = false }
        if let list = try? await store.gitService.listWorktrees(at: project.rootPath) {
            worktrees = list
            if selectedWorktree == nil {
                selectedWorktree = list.first
            }
        }
    }

    private func pruneWorktree(_ wt: GitWorktree, deleteBranch: Bool) async {
        isPruning = true
        defer {
            isPruning = false
            worktreeToPrune = nil
        }
        
        if let session = matchingSession(for: wt) {
            await store.deleteSession(sessionID: session.id, deleteWorktree: true, deleteBranch: deleteBranch)
        } else {
            do {
                try await store.gitService.removeWorktree(
                    at: wt.path,
                    in: project.rootPath,
                    branch: wt.branch,
                    deleteBranch: deleteBranch
                )
            } catch {
                errorMessage = "Failed to remove worktree: \(error.localizedDescription)"
            }
        }
        
        await loadWorktrees()
    }
}
