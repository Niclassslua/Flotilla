import SwiftUI
import SessionKit
import DesignSystem
import GitKit
import ProcessKit

enum SessionCardVariant {
    case row
    case tile
    case board
    case compact
}

struct SessionCard: View {
    let session: Session
    let variant: SessionCardVariant
    let diffStatStore: DiffStatStore?
    let onTap: () -> Void
    let onDelete: () -> Void
    let onRestart: () -> Void
    let onRevealInFinder: () -> Void
    let onCopyPath: () -> Void
    let onCopyBranch: () -> Void
    let isSelected: Bool
    let isActive: Bool

    @Environment(\.flotillaColors) private var colors

    init(
        session: Session,
        variant: SessionCardVariant = .row,
        diffStatStore: DiffStatStore? = nil,
        onTap: @escaping () -> Void = {},
        onDelete: @escaping () -> Void = {},
        onRestart: @escaping () -> Void = {},
        onRevealInFinder: @escaping () -> Void = {},
        onCopyPath: @escaping () -> Void = {},
        onCopyBranch: @escaping () -> Void = {},
        isSelected: Bool = false,
        isActive: Bool = false
    ) {
        self.session = session
        self.variant = variant
        self.diffStatStore = diffStatStore
        self.onTap = onTap
        self.onDelete = onDelete
        self.onRestart = onRestart
        self.onRevealInFinder = onRevealInFinder
        self.onCopyPath = onCopyPath
        self.onCopyBranch = onCopyBranch
        self.isSelected = isSelected
        self.isActive = isActive
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

    private var rowView: some View {
        HStack(alignment: .top, spacing: 10) {
            providerTile
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(SessionRow.compactTimestamp(for: session.lastActiveAt))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    deleteButton
                }
                metadataLine
            }
            .padding(.top, 1)
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu { contextMenu }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Tile Variant (Grid)

    private var tileView: some View {
        VStack(spacing: 0) {
            tileHeader
            Divider()
            tileContent
        }
        .background(colors.terminalCanvas)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(tileBorder)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu { contextMenu }
    }

    private var tileHeader: some View {
        HStack(spacing: 8) {
            Text(session.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(colors.statusReady)
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
                StatusBadge(session.status, variant: .compact)
                Text(StatusPresentation.label(for: session.status))
                    .font(.caption2.weight(.medium))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(StatusPresentation.label(for: session.status))
            .accessibilityIdentifier("GridTile-\(session.title)-Status")

            Button(action: onTap) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Focus on this session")
            .accessibilityIdentifier("GridTile-\(session.title)-FocusButton")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(colors.surface)
    }

    @ViewBuilder
    private var tileContent: some View {
        ContentUnavailableView(
            "Agent Stopped",
            systemImage: "exclamationmark.terminal",
            description: Text("Open this session to restart it.")
        )
    }

    private var tileBorder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(
                isActive
                    ? colors.accent.opacity(0.75)
                    : session.status == .waitingForInput
                    ? colors.statusWaitingForInput.opacity(0.8)
                    : colors.separator.opacity(0.75),
                lineWidth: isActive || session.status == .waitingForInput ? 1.5 : 1
            )
    }

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
        .background(colors.surfaceElevated, in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                .strokeBorder(colors.separator)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onTap)
        .contextMenu { contextMenu }
    }

    private var cardHeader: some View {
        HStack(spacing: 8) {
            StatusBadge(session.status, variant: .compact)

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
                }
            }

            Spacer()

            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var terminalPlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)

            Text("No terminal output")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
        .background(colors.terminalCanvas, in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
    }

    private var gitDiffBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let worktree = session.worktree {
                Text(worktree.branchName)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
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
        .background(colors.surface, in: Capsule())
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
        }
    }

    // MARK: - Compact Variant (Activity strip, etc.)

    private var compactView: some View {
        StatusBadge(session.status, variant: .compact)
    }

    // MARK: - Shared Components

    private var providerTile: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(colors.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(colors.separator.opacity(0.6), lineWidth: 0.5)
                }
                .overlay {
                    ProviderLogo(agent: session.agent)
                        .padding(5)
                }
            statusBeacon
                .offset(x: 4, y: 4)
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }

    private var statusBeacon: some View {
        ZStack {
            Circle()
                .stroke(statusColor, lineWidth: 1)
                .frame(width: 8, height: 8)
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(colors.sidebar, lineWidth: 1.5))
        }
        .frame(width: 16, height: 16)
    }

    private var statusColor: Color {
        switch session.status {
        case .working: return colors.statusWorking
        case .idle: return colors.statusIdle
        case .waitingForInput: return colors.statusWaitingForInput
        case .ready: return colors.statusReady
        case .finished: return colors.statusFinished
        case .crashed: return colors.statusCrashed
        }
    }

    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "trash")
                .font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .secondary : .tertiary)
        .help("Delete Session…")
        .accessibilityLabel("Delete Session")
        .accessibilityIdentifier("SessionRow-\(session.title)-DeleteButton")
    }

    private var metadataLine: some View {
        HStack(spacing: 5) {
            statusWord
            Text("·")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let branch = session.worktree?.branchName {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 8, weight: .medium))
                Text(branch)
                    .font(.caption2.monospaced())
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            } else {
                Text(session.agent.displayName)
                    .font(.caption2)
            }
            if let diffStatStore {
                Spacer(minLength: 2)
                SessionDiffStatView(session: session, diffStatStore: diffStatStore)
            }
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var statusWord: some View {
        ZStack(alignment: .leading) {
            ForEach(StatusPresentation.attentionOrder, id: \.self) { status in
                Text(StatusPresentation.label(for: status)).hidden()
            }
            Text(StatusPresentation.label(for: session.status))
                .foregroundStyle(statusColor)
        }
        .font(.caption2.weight(.semibold))
        .fixedSize()
        .animation(.easeInOut(duration: 0.18), value: session.status)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(backgroundFill)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(colors.separator, lineWidth: 0.5)
                }
            }
    }

    private var backgroundFill: Color {
        if isSelected { return colors.surfaceElevated }
        if session.status == .waitingForInput { return colors.statusWaitingForInput.opacity(isSelected ? 0.13 : 0.08) }
        return isSelected ? Color.white.opacity(0.035) : .clear
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