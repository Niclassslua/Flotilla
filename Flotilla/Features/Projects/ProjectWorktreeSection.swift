import SwiftUI
import AppKit
import SessionKit
import GitKit
import DesignSystem

/// Worktree list section extracted from ProjectWorktreeMatrixView.
/// Used by ProjectOverviewView as one of its three sections and by
/// the Git tab for worktree-scoped Changes.
struct ProjectWorktreeSection: View {
    let project: Project
    let sessions: [Session]
    @Bindable var store: AppStore
    let openSession: (UUID) -> Void
    let onOpenInGit: (GitWorktree) -> Void

    @State private var worktrees: [GitWorktree] = []
    @State private var isLoading = false
    @State private var worktreeToPrune: GitWorktree?
    @State private var showPruneConfirmation = false
    @State private var isPruning = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            HomeSectionHeader(title: "Worktrees", count: worktrees.count)

            if isLoading && worktrees.isEmpty {
                ProgressView("Scanning worktrees…")
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if worktrees.isEmpty {
                HomeEmptyHint(text: "No isolated worktrees found. Launch a session with \"New worktree\" enabled to create one.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(worktrees.enumerated()), id: \.element.path) { index, wt in
                        if index > 0 { Divider().opacity(0.5) }
                        worktreeRow(for: wt)
                    }
                }
            }
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
        .accessibilityIdentifier(AXID.projectWorktreesSection.rawValue)
    }

    // MARK: - Row

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
                    StatusBadge(session.status, waitingReason: session.waitingReason, size: .micro, showLabel: false)
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
                    onOpenInGit(wt)
                } label: {
                    Label("Open in Git", systemImage: "arrow.triangle.branch")
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
                .strokeBorder(FlotillaColors.separator.opacity(0.5))
        }
    }

    // MARK: - Helpers

    func matchingSession(for wt: GitWorktree) -> Session? {
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

    func dummySession(for wt: GitWorktree) -> Session {
        Session(
            title: wt.branch,
            goal: "Worktree: \(wt.branch)",
            agent: .claudeCode,
            projectID: project.id,
            workingDirectory: wt.path
        )
    }

    func loadWorktrees() async {
        isLoading = true
        defer { isLoading = false }
        if let list = try? await store.gitService.listWorktrees(at: project.rootPath) {
            worktrees = list
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
