import SwiftUI
import SessionKit
import GitKit
import DesignSystem

private struct HomeWidgetDiffStatLabel: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(additions.formatted())").foregroundStyle(FlotillaColors.diffAdded)
            Text("−\(deletions.formatted())").foregroundStyle(FlotillaColors.diffRemoved)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
    }
}

// MARK: - Needs You

struct NeedsYouWidgetContent: View {
    let size: HomeWidgetSize
    let items: [HomeWaitingItem]
    let openSession: (UUID) -> Void

    var body: some View {
        if items.isEmpty {
            HomeWidgetAllClearState()
        } else if size == .small {
            small
        } else {
            list(max: size == .large ? 6 : 3)
        }
    }

    private var small: some View {
        let oldest = items.first
        return VStack(alignment: .leading, spacing: 2) {
            Spacer(minLength: 0)
            Text("\(items.count)")
                .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(FlotillaColors.statusWaitingForInput)
            Text(items.count == 1 ? "session waiting" : "sessions waiting")
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textSecondary)
            if let oldest {
                Text("oldest \(HomeTimestamp.compact(oldest.since))")
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
        }
        .onTapGesture { if let oldest { openSession(oldest.session.id) } }
    }

    private func list(max: Int) -> some View {
        VStack(spacing: 6) {
            ForEach(items.prefix(max)) { item in
                Button { openSession(item.session.id) } label: {
                    row(item)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func row(_ item: HomeWaitingItem) -> some View {
        HStack(spacing: FlotillaSpacing.small) {
            Image(systemName: StatusPresentation.glyph(for: .waitingForInput, waitingReason: item.session.waitingReason))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FlotillaColors.statusWaitingForInput)
                .frame(width: 26, height: 26)
                .background(FlotillaColors.statusWaitingForInput.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(item.session.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    ProviderLogo(agent: item.session.agent).frame(width: 10, height: 10)
                    Text("\(item.project.name) · \(StatusPresentation.label(for: .waitingForInput, waitingReason: item.session.waitingReason))")
                        .font(FlotillaTypography.caption2)
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(HomeTimestamp.compact(item.since))
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(FlotillaColors.statusWaitingForInput)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Review Queue

struct ReviewQueueWidgetContent: View {
    let size: HomeWidgetSize
    let items: [HomeReviewItem]
    let openSession: (UUID) -> Void

    /// Rows that fit: two in a medium card, five with a footer in a large one.
    private var visibleRows: Int { size == .large ? 5 : 2 }

    var body: some View {
        if items.isEmpty {
            HomeWidgetAllClearState(message: "Nothing to review")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.prefix(visibleRows).enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider().overlay(FlotillaColors.separator).padding(.leading, 30)
                    }
                    Button { openSession(item.session.id) } label: { row(item) }
                        .buttonStyle(.plain)
                        .padding(.vertical, 7)
                }
                Spacer(minLength: 0)
                if size == .large, let oldest = items.first {
                    HStack {
                        Text("Oldest finished \(HomeTimestamp.compact(oldest.session.statusChangedAt ?? oldest.session.lastActiveAt)) ago")
                            .font(FlotillaTypography.caption2)
                            .foregroundStyle(FlotillaColors.textTertiary)
                        Spacer()
                        Button("Review oldest") { openSession(oldest.session.id) }
                            .font(.system(size: 12, weight: .semibold))
                            .buttonStyle(.plain)
                            .foregroundStyle(FlotillaColors.accentContent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(FlotillaColors.accent, in: Capsule())
                    }
                }
            }
        }
    }

    private func row(_ item: HomeReviewItem) -> some View {
        HStack(alignment: .top, spacing: FlotillaSpacing.small + 2) {
            ProviderLogo(agent: item.session.agent)
                .frame(width: 16, height: 16)
                .padding(3)
                .background(FlotillaColors.textPrimary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.session.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(HomeTimestamp.compact(item.session.statusChangedAt ?? item.session.lastActiveAt))
                        .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .semibold))
                    Text("\(item.project.name) · \(item.session.worktree?.branchName ?? "main")")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    HomeWidgetDiffStatLabel(additions: item.stat.additions, deletions: item.stat.deletions)
                    Text("· \(item.fileCount) files").font(FlotillaTypography.caption2)
                }
                .font(FlotillaTypography.caption2)
                .foregroundStyle(FlotillaColors.textTertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Loose Ends

struct LooseEndsWidgetContent: View {
    struct ProjectRow: Identifiable {
        let id: UUID
        let name: String
        let state: HomeRepoState
    }

    let size: HomeWidgetSize
    let rows: [ProjectRow]

    var body: some View {
        let dirty = rows.filter { !$0.state.isSettled }
        if dirty.isEmpty {
            HomeWidgetAllClearState(message: "Nothing loose")
        } else if size == .small {
            // Totals only, stacked: a small card has no room for per-project rows.
            VStack(alignment: .leading, spacing: 2) {
                figure(rows.map(\.state.changedFileCount).reduce(0, +), "uncommitted", FlotillaColors.statusWaitingForInput)
                figure(rows.map(\.state.unpushedCount).reduce(0, +), "unpushed", FlotillaColors.accent)
                figure(rows.map(\.state.worktreeCount).reduce(0, +), "worktrees", FlotillaColors.textSecondary)
            }
        } else {
            VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
                HStack(spacing: FlotillaSpacing.large) {
                    figure(rows.map(\.state.changedFileCount).reduce(0, +), "uncommitted", FlotillaColors.statusWaitingForInput)
                    figure(rows.map(\.state.unpushedCount).reduce(0, +), "unpushed", FlotillaColors.accent)
                    figure(rows.map(\.state.worktreeCount).reduce(0, +), "worktrees", FlotillaColors.textSecondary)
                }
                VStack(spacing: 4) {
                    ForEach(dirty.prefix(3)) { row in
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill").font(.system(size: 9)).foregroundStyle(FlotillaColors.textTertiary)
                            Text(row.name).font(.system(size: 11, weight: .medium)).foregroundStyle(FlotillaColors.textSecondary)
                            Spacer()
                            if row.state.changedFileCount > 0 { chip("pencil", "\(row.state.changedFileCount)", FlotillaColors.statusWaitingForInput) }
                            if row.state.unpushedCount > 0 { chip("arrow.up", "\(row.state.unpushedCount)", FlotillaColors.accent) }
                            if row.state.worktreeCount > 0 { chip("square.stack.3d.up", "\(row.state.worktreeCount)", FlotillaColors.textTertiary) }
                        }
                    }
                }
            }
        }
    }

    private func figure(_ value: Int, _ label: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)")
                .font(.system(size: size == .small ? 18 : 22, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
            Text(label).font(FlotillaTypography.caption2).foregroundStyle(FlotillaColors.textTertiary)
        }
    }

    private func chip(_ glyph: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: glyph).font(.system(size: 8, weight: .bold))
            Text(value).font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(tint.opacity(0.13), in: Capsule())
    }
}
