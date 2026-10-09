import SwiftUI
import SessionKit
import DesignSystem
import GitKit

enum SessionCardVariant {
    case row
    case tile
    case board
    case compact
}

struct SessionCard<Terminal: View>: View {
    let session: Session
    let variant: SessionCardVariant
    let diffStatStore: DiffStatStore?
    let activityStore: SessionActivityStore?
    /// CI for the session's branch, shown in the sidebar row when it is red
    /// or running. `nil` where CI is not tracked.
    let ciState: CICheckState?
    let isSelected: Bool
    let isActive: Bool
    let onTap: () -> Void
    let onDelete: () -> Void
    let onRestart: () -> Void
    let onRevealInFinder: () -> Void
    let onCopyPath: () -> Void
    let onCopyBranch: () -> Void
    @ViewBuilder let terminal: () -> Terminal

    init(
        session: Session,
        variant: SessionCardVariant = .row,
        diffStatStore: DiffStatStore? = nil,
        activityStore: SessionActivityStore? = nil,
        ciState: CICheckState? = nil,
        isSelected: Bool = false,
        isActive: Bool = false,
        onTap: @escaping () -> Void = {},
        onDelete: @escaping () -> Void = {},
        onRestart: @escaping () -> Void = {},
        onRevealInFinder: @escaping () -> Void = {},
        onCopyPath: @escaping () -> Void = {},
        onCopyBranch: @escaping () -> Void = {},
        @ViewBuilder terminal: @escaping () -> Terminal = { EmptyView() }
    ) {
        self.session = session
        self.variant = variant
        self.diffStatStore = diffStatStore
        self.activityStore = activityStore
        self.ciState = ciState
        self.isSelected = isSelected
        self.isActive = isActive
        self.onTap = onTap
        self.onDelete = onDelete
        self.onRestart = onRestart
        self.onRevealInFinder = onRevealInFinder
        self.onCopyPath = onCopyPath
        self.onCopyBranch = onCopyBranch
        self.terminal = terminal
    }

    var body: some View {
        switch variant {
        case .row:
            rowView
        case .tile:
            tileView
        case .board:
            boardView
        case .compact:
            compactView
        }
    }

    // MARK: - Row Variant (Sidebar)

    /// One navigator row layout for every appearance. Material (glass vs
    /// opaque) stays on the surrounding chrome; the row content does not fork.
    ///
    /// Plain content, not a `Button`: inside a `List` on macOS, wrapping row
    /// content in a `Button` wins the hit-test race and swallows the click
    /// before AppKit's own table-view selection ever sees it — which also
    /// swallows modifier keys, breaking ⌘/Shift-click multi-select. Letting
    /// the table view own the click is what makes `List`'s native selection
    /// (and its `Set`-based multi-select) work; `onTap` still fires from the
    /// context menu's "Open Session" item. Deletion lives on the row's
    /// `.swipeActions` (see the call site in `SessionSidebarRow`) and the
    /// context menu, exactly like Mail and Reminders — the row itself carries
    /// no inline delete control.
    private var rowView: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                ProviderLogo(agent: session.agent)
                    .frame(width: 13, height: 13)
                    .accessibilityHidden(true)
                Text(session.model ?? session.agent.displayName)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(compactTimestamp(for: session.lastActiveAt))
                    .monospacedDigit()
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(isSelected ? FlotillaColors.textSecondary : FlotillaColors.textTertiary)

            Text(session.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FlotillaColors.textPrimary)
                .lineLimit(1)

            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                Text(StatusPresentation.label(for: session.status, waitingReason: session.waitingReason))
                    .foregroundStyle(statusColor)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(StatusPresentation.label(for: session.status, waitingReason: session.waitingReason))
                    .accessibilityIdentifier("SessionRow-\(session.title)-Status")
                if let branch = session.worktree?.branchName {
                    Text("·")
                        .foregroundStyle(isSelected ? FlotillaColors.textSecondary : FlotillaColors.textTertiary)
                    Text(BranchNaming.displayName(for: branch))
                        .foregroundStyle(isSelected ? FlotillaColors.textSecondary : FlotillaColors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                CIStatusGlyph(state: ciState, quiet: true)
                if let diffStatStore {
                    SessionDiffStatView(session: session, diffStatStore: diffStatStore, style: .plain)
                }
            }
            .font(.system(size: 10, weight: .medium))
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu { contextMenu }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Tile Variant (Grid) — Dense status card + last output line

    private var tileView: some View {
        VStack(spacing: 0) {
            tileHeader
            Divider()
            tileContent
        }
        .flotillaLiquidSurface(
            FlotillaColors.terminalCanvas,
            cornerRadius: 8,
            glassTintOpacity: FlotillaGlassTint.terminal
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(tileBorder)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu { contextMenu }
        .accessibilityIdentifier(variant == .board ? "KanbanCard-\(session.title)" : "GridTile-\(session.title)")
    }

    private var tileHeader: some View {
        HStack(spacing: 8) {
            Text(session.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(FlotillaColors.textPrimary)
                .lineLimit(1)
            Text("/")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack(spacing: 4) {
                ProviderLogo(agent: session.agent)
                    .frame(width: 11, height: 11)
                Text(session.agent.displayName)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 4) {
                StatusBadge(session.status, waitingReason: session.waitingReason, variant: .compact)
                Text(StatusPresentation.label(for: session.status, waitingReason: session.waitingReason))
                    .font(.caption2.weight(.medium))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(StatusPresentation.label(for: session.status, waitingReason: session.waitingReason))
            .accessibilityIdentifier(variant == .board ? "KanbanCard-\(session.title)-Status" : "GridTile-\(session.title)-Status")

            Button(action: onTap) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Focus on this session")
            .accessibilityIdentifier(variant == .board ? "KanbanCard-\(session.title)-FocusButton" : "GridTile-\(session.title)-FocusButton")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(FlotillaColors.surface)
    }

    @ViewBuilder
    private var tileContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Branch / Diff stat
            HStack(spacing: 8) {
                if let branch = session.worktree?.branchName {
                    GitBranchIcon(size: 10)
                        .foregroundStyle(.secondary)
                    Text(BranchNaming.displayName(for: branch))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let diffStatStore {
                    Spacer(minLength: 2)
                    SessionDiffStatView(session: session, diffStatStore: diffStatStore)
                }
            }

            // Last output line
            if let activityStore,
               let lastLine = activityStore.lastOutputLine(for: session.id) {
                Text(lastLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // Elapsed time
            HStack {
                Text(elapsedTime)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tileBorder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(
                isActive
                    ? FlotillaColors.accent.opacity(0.75)
                    : session.status == .waitingForInput
                    ? FlotillaColors.statusWaitingForInput.opacity(0.8)
                    : FlotillaColors.separator.opacity(0.75),
                lineWidth: isActive || session.status == .waitingForInput ? 1.5 : 1
            )
    }

    private var elapsedTime: String { SessionElapsed.since(session.createdAt) }

    // MARK: - Board Variant (Kanban)

    private var boardView: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHeader

            terminalPlaceholder

            if session.worktree != nil {
                gitDiffBadge
            }

            if !session.goal.isEmpty {
                goalProgress
            }
        }
        .padding(10)
        .flotillaLiquidSurface(
            FlotillaColors.surfaceElevated,
            cornerRadius: FlotillaRadius.card,
            glassTintOpacity: FlotillaGlassTint.elevated
        )
        .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                .strokeBorder(FlotillaColors.separator)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onTap)
        .contextMenu { contextMenu }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("KanbanCard-\(session.title)")
    }

    private var cardHeader: some View {
        HStack(spacing: 8) {
            StatusBadge(session.status, waitingReason: session.waitingReason, variant: .compact)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    ProviderLogo(agent: session.agent)
                        .frame(width: 10, height: 10)

                    Text(session.agent.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("SessionCard.AgentName")
                }
            }

            Spacer()

            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var terminalPlaceholder: some View {
        terminal()
    }

    private var gitDiffBadge: some View {
        HStack(spacing: 8) {
            GitBranchIcon(size: 11)
                .foregroundStyle(.secondary)

            if let worktree = session.worktree {
                Text(BranchNaming.displayName(for: worktree.branchName))
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("SessionCard.BranchName")
            }

            Spacer()

            if let diffStatStore {
                SessionDiffStatView(session: session, diffStatStore: diffStatStore)
            } else {
                Text("±0")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(FlotillaColors.surface, in: Capsule())
    }

    private var goalProgress: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Goal")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(session.goal)
                .font(.caption)
                .lineLimit(3)
                .foregroundStyle(.primary)
                .accessibilityIdentifier("SessionCard.GoalText")
        }
    }

    // MARK: - Compact Variant (Activity strip, etc.)

    private var compactView: some View {
        StatusBadge(session.status, waitingReason: session.waitingReason, variant: .compact)
    }

    // MARK: - Shared Components

    private var statusColor: Color {
        StatusPresentation.color(for: session.status)
    }

    private func compactTimestamp(for date: Date, relativeTo now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<90: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Open Session") {
            onTap()
        }
        Divider()
        Button("Restart Session") {
            onRestart()
        }
        .accessibilityIdentifier("Restart Session")
        Button("Reveal in Finder") {
            onRevealInFinder()
        }
        Button("Copy Path") {
            onCopyPath()
        }
        Button("Copy Branch") {
            onCopyBranch()
        }
        Divider()
        Button("Delete Session…", role: .destructive) {
            onDelete()
        }
    }
}
