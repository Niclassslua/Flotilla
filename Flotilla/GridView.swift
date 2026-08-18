import SwiftUI
import SessionKit
import DesignSystem

/// Dispatches to one of the candidate grid designs and owns everything they
/// share: which sessions are visible, their order, and the per-tile actions.
///
/// The layout controls live in `WorkspaceToolbar`, not here — an inline
/// control bar cost vertical space on every render of a view whose whole job
/// is showing terminals.
struct GridView: View {
    let store: AppStore
    let terminalManager: TerminalManager
    @Binding var activeSessionID: UUID?
    let openSession: (UUID) -> Void
    var projectFilter: UUID? = nil
    @Bindable var settingsViewModel: SettingsViewModel

    @State private var pendingDeletion: Session?

    private var zoom: GridZoom {
        GridZoom(setting: settingsViewModel.settings.workspace.gridMinimumTileWidth)
    }

    private var visibleSessions: [Session] {
        let scoped = projectFilter.map { filter in
            store.sessions.filter { $0.projectID == filter }
        } ?? store.sessions
        return scoped.ordered(by: settingsViewModel.settings.workspace.gridSessionOrder)
    }

    var body: some View {
        Group {
            if visibleSessions.isEmpty {
                ContentUnavailableView(
                    store.sessions.isEmpty ? "No Live Sessions" : "No Sessions in This Project",
                    systemImage: "square.grid.2x2",
                    description: Text(store.sessions.isEmpty
                        ? "Launch sessions to assemble a live grid."
                        : "Choose another project or return to all sessions.")
                )
                .accessibilityIdentifier("GridEmptyState")
            } else {
                grid
                    .accessibilityIdentifier("GridView")
                    .gridZoomGestures(isEnabled: true) { factor in
                        apply(zoom.scaled(by: factor))
                    }
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
            zoom: zoom,
            activeSessionID: activeSessionID,
            actions: actions(for:)
        )
    }

    private func apply(_ newZoom: GridZoom) {
        guard newZoom != zoom else { return }
        settingsViewModel.settings.workspace.gridMinimumTileWidth = newZoom.setting
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
            }
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
        // Sessions outside the current filter keep their saved position.
        let untouched = settingsViewModel.settings.workspace.gridSessionOrder
            .filter { !reordered.contains($0) }
        settingsViewModel.settings.workspace.gridSessionOrder = reordered + untouched
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
