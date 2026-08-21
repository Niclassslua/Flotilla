import SwiftUI
import SessionKit
import DesignSystem
import TerminalKit

/// The per-tile actions every grid design offers. Bundled into one value so
/// the four designs pass a single parameter instead of repeating seven
/// closures each.
struct SessionTileActions {
    var onActivate: () -> Void = {}
    var onOpenSession: () -> Void = {}
    var onDelete: () -> Void = {}
    var onRestart: () -> Void = {}
    var onRevealInFinder: () -> Void = {}
    var onCopyPath: () -> Void = {}
    var onCopyBranch: () -> Void = {}
    /// Another tile was dropped onto this one; move the dragged session to
    /// this tile's position.
    var onDropSession: (UUID) -> Void = { _ in }
}

// MARK: - Identity

/// Status dot, title, and provider mark. The pieces truncate in priority
/// order: the provider name goes first, then the title, so the status dot and
/// title stay legible even in a narrow tile.
struct TileTitleLockup: View {
    let session: Session
    var showsProviderName = true
    var font: Font = .caption.weight(.medium)

    var body: some View {
        HStack(spacing: 6) {
            // Collapsed into one element so the dot reports the status as its
            // label; the UI suite asserts on exactly this.
            StatusBadge(session.status, variant: .compact)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(StatusPresentation.label(for: session.status))
                .accessibilityIdentifier("GridTile-\(session.title)-Status")

            Text(session.title)
                .font(font)
                .foregroundStyle(FlotillaColors.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)

            ProviderLogo(agent: session.agent)
                .frame(width: 11, height: 11)

            if showsProviderName {
                Text(session.agent.displayName)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
        }
    }
}

/// Branch, diff stat, and elapsed time on one line. Every design shows this
/// somewhere; only the placement differs.
struct TileMetaRow: View {
    let session: Session
    let store: AppStore
    var showsElapsed = true

    var body: some View {
        HStack(spacing: 6) {
            if let branch = session.worktree?.branchName {
                Label {
                    Text(branch)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "arrow.triangle.branch")
                }
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            SessionDiffStatView(session: session, diffStatStore: store.diffStatStore)

            if showsElapsed {
                Text(Self.elapsed(since: session.createdAt))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 10, design: .monospaced))
    }

    static func elapsed(since start: Date) -> String {
        let interval = Date().timeIntervalSince(start)
        switch interval {
        case ..<60: return "\(Int(interval))s"
        case ..<3600: return "\(Int(interval / 60))m"
        case ..<86400: return "\(Int(interval / 3600))h"
        default: return "\(Int(interval / 86400))d"
        }
    }
}

/// Opens the session full-screen. Split out because every design needs it and
/// the accessibility identifier is asserted by the UI test suite.
struct TileFocusButton: View {
    let session: Session
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .medium))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Focus on this session")
        .accessibilityIdentifier("GridTile-\(session.title)-FocusButton")
    }
}

// MARK: - Terminal body

/// The live terminal for a tile, or a single stopped-state placeholder.
///
/// Every tile hosts a real `TerminalPresentation.grid` renderer — the grid is
/// meant for watching a fleet actually run, so nothing here downgrades to a
/// static preview.
struct TileTerminalBody: View {
    let session: Session
    let store: AppStore
    let terminalManager: TerminalManager
    let isActive: Bool
    let onActivate: () -> Void
    let onRestart: () -> Void

    var body: some View {
        if let process = store.process(for: session.id) {
            ZStack {
                TerminalHostView(
                    controller: terminalManager.controller(
                        for: session,
                        process: process,
                        scrollback: store.scrollback(for: session.id),
                        customReflowHandler: store.customReflowHandler(for: session.id),
                        onPTYResize: store.resizeHandler(for: session.id),
                        outputHandler: { [weak store] data in
                            store?.appendTerminalOutput(data, toSessionID: session.id)
                        },
                        // See ContentView.terminal(for:) — keystrokes
                        // are not evidence the agent is working.
                        inputHandler: {}
                    ),
                    presentation: .grid,
                    isFocused: isActive
                )
                .id(process.id)

                // An inactive tile should activate on click rather than
                // sending the click through to the terminal.
                if !isActive {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onActivate)
                        .accessibilityHidden(true)
                }
            }
            .background(FlotillaColors.terminalCanvas)
        } else {
            ContentUnavailableView {
                Label("Agent Stopped", systemImage: "exclamationmark.terminal")
            } description: {
                Text("This session is no longer running.")
            } actions: {
                Button("Restart Session", action: onRestart)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FlotillaColors.terminalCanvas)
        }
    }
}

// MARK: - Surface

/// Card background, border, context menu, and drag source — the parts that are
/// identical across designs. The border colour carries state: accent when
/// active, the waiting-for-input colour when the agent needs the user.
struct SessionTileSurface: ViewModifier {
    let session: Session
    let isActive: Bool
    let actions: SessionTileActions
    var cornerRadius: CGFloat = 8

    @State private var isDropTarget = false

    private var borderColor: Color {
        if isDropTarget { return FlotillaColors.accent }
        if isActive { return FlotillaColors.accent.opacity(0.75) }
        if session.status == .waitingForInput { return FlotillaColors.statusWaitingForInput.opacity(0.8) }
        return FlotillaColors.separator.opacity(0.75)
    }

    private var borderWidth: CGFloat {
        if isDropTarget { return 2 }
        return isActive || session.status == .waitingForInput ? 1.5 : 1
    }

    func body(content: Content) -> some View {
        content
            .background(FlotillaColors.terminalCanvas)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            }
            .contextMenu {
                // Bare buttons: a `contextMenu` builds a native NSMenu, so a
                // styled container here renders as a stack of controls
                // instead of menu items.
                Button("Restart", action: actions.onRestart)
                Button("Reveal in Finder", action: actions.onRevealInFinder)
                Button("Copy Path", action: actions.onCopyPath)
                if session.worktree?.branchName != nil {
                    Button("Copy Branch", action: actions.onCopyBranch)
                }
                Divider()
                Button("Delete Session…", role: .destructive, action: actions.onDelete)
            }
            .draggable(session.id.uuidString) {
                TileDragPreview(session: session)
                    .frame(width: 120, height: 44)
            }
            // Pairs with `draggable` above. Without this the drag could start
            // but never land, which is how the previous grid shipped.
            .dropDestination(for: String.self) { items, _ in
                guard let dragged = items.first.flatMap(UUID.init(uuidString:)),
                      dragged != session.id
                else { return false }
                actions.onDropSession(dragged)
                return true
            } isTargeted: { targeted in
                isDropTarget = targeted
            }
    }
}

extension View {
    func sessionTileSurface(
        session: Session,
        isActive: Bool,
        actions: SessionTileActions,
        cornerRadius: CGFloat = 8
    ) -> some View {
        modifier(
            SessionTileSurface(
                session: session,
                isActive: isActive,
                actions: actions,
                cornerRadius: cornerRadius
            )
        )
    }
}

private struct TileDragPreview: View {
    let session: Session

    var body: some View {
        HStack(spacing: 6) {
            StatusBadge(session.status, variant: .compact)
            Text(session.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            ProviderLogo(agent: session.agent)
                .frame(width: 12, height: 12)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlotillaColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
