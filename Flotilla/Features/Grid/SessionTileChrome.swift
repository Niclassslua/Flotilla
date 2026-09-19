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
    /// Takes this session out of the grid without deleting it. Same call the
    /// navigator's membership control makes, so the two cannot diverge.
    var onRemoveFromGrid: () -> Void = {}
    /// Commits an inline rename from the tile's own bar.
    var onRename: (String) -> Void = { _ in }
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
                    .tint(FlotillaColors.accent)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FlotillaColors.terminalCanvas)
        }
    }
}

// MARK: - Surface

/// Card background, border, context menu, and drag source — the parts that are
/// identical across designs.
///
/// The border is reserved for the one state that needs a human *now*. It used
/// to carry accent for "selected" as well, at the same 1.5pt in a near
/// identical hue, so the tile's one glanceable channel answered "which is
/// selected" instead of "which needs me". Selection moved to an inset ring,
/// which reads as chrome rather than as state.
///
/// Crashed deliberately gets no border: the tile's `SessionBar` already
/// spells the status out in words, so the state is carried (and carried
/// accessibly) without painting a grid of red rectangles.
struct SessionTileSurface: ViewModifier {
    let session: Session
    let isActive: Bool
    let actions: SessionTileActions
    var cornerRadius: CGFloat = 8

    @State private var isDropTarget = false

    private var needsInput: Bool { session.status == .waitingForInput }

    private var borderColor: Color {
        // A drag in progress is transient chrome, so it may briefly outrank
        // status; everything else defers to it.
        if isDropTarget { return FlotillaColors.accent }
        if needsInput { return FlotillaColors.statusWaitingForInput.opacity(0.8) }
        return FlotillaColors.separator.opacity(0.75)
    }

    private var borderWidth: CGFloat {
        if isDropTarget { return 2 }
        return needsInput ? 1.5 : 1
    }

    func body(content: Content) -> some View {
        content
            .background(FlotillaColors.terminalCanvas)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            }
            .overlay {
                // Selection: an inset ring, inside the border and separated
                // from it by a gap, so the two never read as one signal at a
                // glance.
                if isActive {
                    RoundedRectangle(cornerRadius: cornerRadius - 3, style: .continuous)
                        .strokeBorder(FlotillaColors.accent, lineWidth: 1.5)
                        .padding(3)
                }
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

struct TileDragPreview: View {
    let session: Session

    var body: some View {
        HStack(spacing: 8) {
            StatusBadge(session.status, waitingReason: session.waitingReason, variant: .compact)
            Text(session.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(FlotillaColors.textPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            ProviderLogo(agent: session.agent)
                .frame(width: 12, height: 12)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(FlotillaColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                .strokeBorder(FlotillaColors.separator.opacity(0.8), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
    }
}
