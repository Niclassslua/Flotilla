import SwiftUI
import SessionKit
import DesignSystem

/// Dispatches to one of the candidate grid designs and owns everything they
/// share: which sessions are visible, their order, and the per-tile actions.
///
/// The layout controls live in `SessionGroupBar`, the bar directly above this
/// view. They used to sit in the window toolbar to save the vertical space an
/// inline bar costs; that trade is deliberately reversed. The toolbar could
/// only hold them by adding and removing four controls as the selection
/// changed, which moved the always-present buttons beside them, and it left
/// the grid with nowhere to put the group chips at all. Thirty-two points is
/// the price of a bar whose contents hold still.
struct GridView: View {
    let store: AppStore
    let terminalManager: TerminalManager
    @Binding var activeSessionID: UUID?
    let openSession: (UUID) -> Void
    /// What subset of the fleet this grid draws from. Shared with Board and
    /// Focus, so switching presentation changes how the fleet is shown and
    /// never which sessions are in it — see `SessionScope`.
    var scope: SessionScope = .everything
    @Bindable var settingsViewModel: SettingsViewModel

    @State private var pendingDeletion: Session?
    /// Accumulates pinch/Command-scroll magnification between discrete column
    /// steps, so a small nudge doesn't jump the grid by a whole column.
    @State private var zoomAccumulator: CGFloat = 1

    private var dimensions: GridDimensions {
        GridDimensions(
            columns: settingsViewModel.settings.workspace.gridColumnCount,
            rows: settingsViewModel.settings.workspace.gridRowCount
        )
    }

    private var scopedSessions: [Session] {
        scope.apply(to: store.sessions)
    }

    /// The sessions assigned to the grid, capped at what the picker's
    /// dimensions can actually show — see `GridSelection`.
    private var visibleSessions: [Session] {
        GridSelection.visible(
            selectedIDs: settingsViewModel.settings.workspace.gridSelectedSessionIDs,
            in: scopedSessions,
            capacity: dimensions.capacity
        )
    }

    var body: some View {
        Group {
            if scopedSessions.isEmpty {
                // Names the narrowing that produced the emptiness — "no
                // sessions" is unhelpful when the answer is that this smart
                // list happens to be empty right now.
                ContentUnavailableView(
                    scope.isEverything ? "No Live Sessions" : "Nothing in This View",
                    systemImage: "square.grid.2x2",
                    description: Text(scope.emptyDescription)
                )
                .accessibilityIdentifier("GridEmptyState")
            } else if visibleSessions.isEmpty {
                ContentUnavailableView(
                    "No Sessions in the Grid",
                    systemImage: "square.grid.2x2",
                    description: Text("Select sessions from the sidebar, or add as many as fit \(dimensions.label).")
                )
                .accessibilityIdentifier("GridEmptyState")
            } else {
                grid
                    .accessibilityIdentifier("GridView")
                    .gridZoomGestures(isEnabled: true, onZoom: handleZoom)
                    .onAppear(perform: ensureActiveSession)
                    .onChange(of: visibleSessions.map(\.id)) { ensureActiveSession() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlotillaColors.canvas)
        .sheet(item: $pendingDeletion) { session in
            DeleteSessionSheet(
                session: session,
                onCancel: { pendingDeletion = nil },
                onDelete: { deleteWorktree in
                    pendingDeletion = nil
                    Task {
                        await store.deleteSession(
                            sessionID: session.id,
                            deleteWorktree: deleteWorktree,
                            deleteBranch: settingsViewModel.settings.git.deleteBranchWithWorktree
                        )
                    }
                }
            )
        }
    }

    private var grid: some View {
        MissionControlGrid(
            sessions: visibleSessions,
            store: store,
            terminalManager: terminalManager,
            dimensions: dimensions,
            activeSessionID: activeSessionID,
            dimEnabled: settingsViewModel.settings.workspace.gridDimEnabled,
            dimIntensity: settingsViewModel.settings.workspace.gridDimIntensity,
            actions: actions(for:)
        )
    }

    private func apply(_ newDimensions: GridDimensions) {
        guard newDimensions != dimensions else { return }
        settingsViewModel.settings.workspace.gridColumnCount = newDimensions.columns
        settingsViewModel.settings.workspace.gridRowCount = newDimensions.rows
    }

    /// Pinch-out/Command-scroll-down grows the column count (smaller tiles);
    /// the reverse shrinks it. Magnification arrives as many small factors in
    /// a row, so they're multiplied together until the accumulated change is
    /// big enough to justify moving a whole column.
    private func handleZoom(_ factor: CGFloat) {
        zoomAccumulator *= factor
        if zoomAccumulator > 1.15 {
            apply(dimensions.zoomedIn())
            zoomAccumulator = 1
        } else if zoomAccumulator < 0.85 {
            apply(dimensions.zoomedOut())
            zoomAccumulator = 1
        }
    }

    private func actions(for session: Session) -> SessionTileActions {
        SessionTileActions(
            onActivate: { activeSessionID = session.id },
            onOpenSession: { openSession(session.id) },
            onDelete: { pendingDeletion = session },
            onRestart: { store.restartSession(sessionID: session.id) },
            onRevealInFinder: {
                let path = session.worktree?.worktreePath ?? session.workingDirectory
                NSWorkspace.shared.activateFileViewerSelecting([path])
            },
            onCopyPath: {
                let path = session.worktree?.worktreePath ?? session.workingDirectory
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path.path, forType: .string)
            },
            onCopyBranch: {
                guard let branch = session.worktree?.branchName else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(branch, forType: .string)
            },
            onDropSession: { draggedID in
                move(draggedID, toPositionOf: session.id)
            },
            onRemoveFromGrid: {
                settingsViewModel.toggleGridMembership(
                    of: session.id,
                    in: store.sessions,
                    capacity: dimensions.capacity
                )
            },
            onRename: { store.renameSession(sessionID: session.id, newTitle: $0) }
        )
    }

    /// Persists the full visible order rather than a delta, so the saved order
    /// stays meaningful even when the grid is filtered to one project.
    private func move(_ draggedID: UUID, toPositionOf targetID: UUID) {
        var ordered = visibleSessions.map(\.id)
        guard let from = ordered.firstIndex(of: draggedID),
              let to = ordered.firstIndex(of: targetID),
              from != to
        else { return }
        ordered.remove(at: from)
        ordered.insert(draggedID, at: to)

        let reordered = ordered.map(\.uuidString)
        // Sessions outside the current filter (or past capacity) keep their
        // saved position.
        let untouched = settingsViewModel.settings.workspace.gridSelectedSessionIDs
            .filter { !reordered.contains($0) }
        settingsViewModel.settings.workspace.gridSelectedSessionIDs = reordered + untouched
    }

    private func ensureActiveSession() {
        guard !visibleSessions.isEmpty else {
            activeSessionID = nil
            return
        }
        if let activeSessionID, visibleSessions.contains(where: { $0.id == activeSessionID }) {
            return
        }
        if let selectedSessionID = store.selectedSessionID,
           visibleSessions.contains(where: { $0.id == selectedSessionID }) {
            activeSessionID = selectedSessionID
        } else {
            activeSessionID = visibleSessions[0].id
        }
    }
}
