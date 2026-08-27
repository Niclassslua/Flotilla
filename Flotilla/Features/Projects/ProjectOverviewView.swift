import SwiftUI
import SessionKit
import GitKit
import DesignSystem

/// Overview tab for a project — a stacked scroll view mirroring HomeDashboardView's fleet layout.
///
/// Three sections, all using `HomeSectionHeader`:
/// 1. Active sessions (working + waitingForInput)
/// 2. Worktrees (extracted list, no HSplitView)
/// 3. Recent sessions
struct ProjectOverviewView: View {
    let project: Project
    let sessions: [Session]
    @Bindable var store: AppStore
    let openSession: (UUID) -> Void
    let onOpenInGit: (GitWorktree) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FlotillaSpacing.xxLarge) {
                activeSessionsSection
                worktreesSection
                recentSessionsSection
            }
            .padding(.horizontal, FlotillaSpacing.large)
            .padding(.vertical, FlotillaSpacing.large)
        }
        .background(FlotillaColors.canvas)
        .accessibilityIdentifier(AXID.projectOverview.rawValue)
    }

    // MARK: - Active Sessions

    private var activeSessions: [Session] {
        sessions.filter { $0.status == .working || $0.status == .waitingForInput }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    @ViewBuilder
    private var activeSessionsSection: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            HomeSectionHeader(title: "Active sessions", count: activeSessions.count)

            if activeSessions.isEmpty {
                HomeEmptyHint(text: "No sessions are currently active. Start one to see it here.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(activeSessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { Divider().opacity(0.5) }
                        activeSessionRow(session)
                    }
                }
            }
        }
        .accessibilityIdentifier(AXID.projectSessionsSection.rawValue)
    }

    private func activeSessionRow(_ session: Session) -> some View {
        HStack(spacing: FlotillaSpacing.medium) {
            StatusBadge(session.status, waitingReason: session.waitingReason, size: .micro, showLabel: false, showGlyph: true)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(FlotillaTypography.body.weight(.medium))
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)
                Text(session.goal)
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: FlotillaSpacing.small)

            if let branch = session.worktree?.branchName {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .frame(maxWidth: 140, alignment: .trailing)
            }

            Text(session.agent.displayName)
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textSecondary)

            Image(systemName: "chevron.right")
                .font(.system(size: FlotillaIconSize.xSmall, weight: .semibold))
                .foregroundStyle(FlotillaColors.textTertiary)
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small + 2)
        .contentShape(.rect)
        .onTapGesture { openSession(session.id) }
    }

    // MARK: - Worktrees

    private var worktreesSection: some View {
        ProjectWorktreeSection(
            project: project,
            sessions: sessions,
            store: store,
            openSession: openSession,
            onOpenInGit: onOpenInGit
        )
    }

    // MARK: - Recent Sessions

    private var recentSessions: [Session] {
        let activeIDs = Set(activeSessions.map(\.id))
        return sessions
            .filter { !activeIDs.contains($0.id) }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
            .prefix(6)
            .map { $0 }
    }

    @ViewBuilder
    private var recentSessionsSection: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            HomeSectionHeader(title: "Recent sessions", count: sessions.count)

            if recentSessions.isEmpty && activeSessions.isEmpty {
                HomeEmptyHint(text: "Sessions you start will collect here.")
            } else if recentSessions.isEmpty {
                HomeEmptyHint(text: "All sessions are currently active.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recentSessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { Divider().opacity(0.5) }
                        recentSessionRow(session)
                    }
                }
            }
        }
    }

    private func recentSessionRow(_ session: Session) -> some View {
        HStack(spacing: FlotillaSpacing.medium) {
            ProviderLogo(agent: session.agent)
                .frame(width: 22, height: 22)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(StatusPresentation.color(for: session.status))
                        .frame(width: 7, height: 7)
                        .overlay { Circle().strokeBorder(FlotillaColors.canvas, lineWidth: 1.5) }
                        .offset(x: 2, y: 2)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(FlotillaTypography.body)
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)
            }

            Spacer(minLength: FlotillaSpacing.small)

            SessionDiffStatView(session: session, diffStatStore: store.diffStatStore)

            if let branch = session.worktree?.branchName {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .frame(maxWidth: 140, alignment: .trailing)
            }

            Text(HomeTimestamp.compact(session.lastActiveAt))
                .font(FlotillaTypography.caption2.monospacedDigit())
                .foregroundStyle(FlotillaColors.textTertiary)
                .frame(minWidth: 26, alignment: .trailing)
        }
        .padding(.horizontal, FlotillaSpacing.small)
        .padding(.vertical, FlotillaSpacing.small)
        .contentShape(.rect)
        .onTapGesture { openSession(session.id) }
    }
}
