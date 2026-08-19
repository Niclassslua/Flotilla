import SwiftUI
import AppKit
import SessionKit
import GitKit
import DesignSystem
import SettingsKit

/// Focused project view displaying repository status, Worktree Matrix, diff inspection, and project rules.
struct ProjectDetailView: View {
    let project: Project
    let sessions: [Session]
    @Bindable var store: AppStore
    let terminalManager: TerminalManager
    let openSession: (UUID) -> Void
    let openCodeSubscription: OpenCodeSubscription
    let onBackToOverview: () -> Void

    @State private var currentBranch: String?
    @State private var projectDiffStat: GitDiffStat?
    @State private var isShowingRulesSheet = false
    @State private var isShowingCreateSessionSheet = false

    var body: some View {
        VStack(spacing: 0) {
            projectHeader
            Divider()
            ProjectWorktreeMatrixView(
                project: project,
                sessions: sessions,
                store: store,
                openSession: openSession
            )
        }
        .task(id: project.id) {
            if let branch = try? await store.gitService.currentBranch(at: project.rootPath) {
                currentBranch = branch
            }
            if let stat = try? await store.gitService.diffStat(at: project.rootPath) {
                projectDiffStat = stat
            }
        }
        .sheet(isPresented: $isShowingRulesSheet) {
            ProjectRulesSheet(project: project, store: store)
        }
        .sheet(isPresented: $isShowingCreateSessionSheet) {
            CreateSessionView(
                store: store,
                createWorktreeByDefault: true,
                initialProject: project,
                didCreateSession: openSession
            )
        }
    }

    private var projectHeader: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
            HStack(alignment: .center, spacing: FlotillaSpacing.medium) {
                Button(action: onBackToOverview) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                        Text("Overview")
                            .font(FlotillaTypography.caption.weight(.medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(FlotillaColors.surfaceElevated, in: RoundedRectangle(cornerRadius: FlotillaRadius.control))
                }
                .buttonStyle(.plain)
                .help("Back to Overview")
                .accessibilityIdentifier("ProjectDetail.BackButton")

                Divider().frame(height: 20)

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

                    Button {
                        isShowingRulesSheet = true
                    } label: {
                        Label("Rules & Context", systemImage: "doc.badge.gearshape")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("ProjectDetail.RulesButton")
                }
            }
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.medium)
        .background(FlotillaColors.surface)
    }
}
