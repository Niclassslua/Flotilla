import SwiftUI
import SessionKit
import DesignSystem
import TerminalKit
import UniformTypeIdentifiers

struct KanbanTabView: View {
    @Bindable var store: AppStore
    let terminalManager: TerminalManager
    var activityStore: SessionActivityStore? = nil
    let openSession: (UUID) -> Void
    var scope: SessionScope = .everything

    var body: some View {
        let _ = PerfLog.bump("KanbanTabView.body")
        Group {
            if let board = store.selectedKanbanBoard {
                KanbanBoardView(
                    store: store,
                    board: board,
                    terminalManager: terminalManager,
                    activityStore: activityStore,
                    openSession: openSession,
                    scope: scope
                )
            } else {
                ContentUnavailableView(
                    "No Board",
                    systemImage: "square.grid.2x2",
                    description: Text("No Kanban board is available")
                )
            }
        }
        .flotillaLiquidSurface(FlotillaColors.canvas, glassTintOpacity: FlotillaGlassTint.detail)
    }
}

struct KanbanBoardView: View {
    @Bindable var store: AppStore
    let board: KanbanBoard
    let terminalManager: TerminalManager
    let activityStore: SessionActivityStore?
    let openSession: (UUID) -> Void
    var scope: SessionScope = .everything

    /// One namespace shared by every column so a card keeps its identity when
    /// its status changes and it moves from one column to another — SwiftUI
    /// then slides it across the gap instead of cross-fading two cards.
    @Namespace private var cardMotion

    /// The card being dragged for hand-sorting, board-wide so any column's
    /// drop clears it (a card dragged out of column A and dropped on B must
    /// un-dim in A). Reordering itself stays within the origin column.
    @State private var draggingID: UUID?

    /// The board presents session status and nothing else. The agent and
    /// workflow groupings were removed: grouping by agent answered a
    /// question nobody asks, and `workflowStage` is never written by
    /// anything, so those columns were permanently empty.
    private var columns: [KanbanColumn] {
        KanbanColumn.defaultStatusColumns()
    }

    /// Every session the board is currently showing, in column order. Drives
    /// the cross-column move animation and the "does this board mix projects"
    /// check below.
    private var renderedSessions: [Session] {
        columns.flatMap { store.getSessionsForColumn($0, board: board) }
    }

    /// Cards name their project only when the board actually mixes projects.
    /// A project-scoped board, or any group narrower than All, makes every
    /// card's project identical, so the label would be pure noise. That
    /// includes the General group, whose cards all share *no* project.
    private var showsProjectName: Bool {
        guard board.projectID == nil, scope.group == .all else { return false }
        return Set(renderedSessions.map(\.projectID)).count > 1
    }

    private static let columnSpacing: CGFloat = 14
    private static let boardPadding: CGFloat = 16
    /// Below this a column can no longer hold a branch name and a status
    /// chip without crushing them, so the board starts scrolling instead of
    /// shrinking further.
    private static let minColumnWidth: CGFloat = 280

    /// Columns share the container width equally, growing past their minimum
    /// rather than leaving a gutter of unused canvas on the trailing edge.
    /// Only when the window is too narrow for every column at its minimum
    /// does the board fall back to horizontal scrolling.
    private func columnWidth(forAvailable available: CGFloat) -> CGFloat {
        let count = CGFloat(columns.count)
        guard count > 0 else { return Self.minColumnWidth }
        let gutters = Self.boardPadding * 2 + Self.columnSpacing * (count - 1)
        return max(Self.minColumnWidth, (available - gutters) / count)
    }

    var body: some View {
        let _ = PerfLog.bump("KanbanBoardView.body")
        GeometryReader { proxy in
            let width = columnWidth(forAvailable: proxy.size.width)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Self.columnSpacing) {
                    ForEach(columns) { column in
                        KanbanColumnView(
                            store: store,
                            board: board,
                            column: column,
                            terminalManager: terminalManager,
                            activityStore: activityStore,
                            openSession: openSession,
                            width: width,
                            scope: scope,
                            showProjectName: showsProjectName,
                            cardMotion: cardMotion,
                            draggingID: $draggingID
                        )
                    }
                }
                .padding(Self.boardPadding)
                .frame(minHeight: proxy.size.height, alignment: .top)
                .animation(FlotillaMotion.spring.curve, value: renderedSessions)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .flotillaLiquidSurface(FlotillaColors.canvas, glassTintOpacity: FlotillaGlassTint.detail)
        .accessibilityIdentifier("KanbanBoard")
    }
}

struct KanbanColumnView: View {
    @Bindable var store: AppStore
    let board: KanbanBoard
    let column: KanbanColumn
    let terminalManager: TerminalManager
    let activityStore: SessionActivityStore?
    let openSession: (UUID) -> Void
    let width: CGFloat
    var scope: SessionScope = .everything
    var showProjectName: Bool = false
    var cardMotion: Namespace.ID
    /// The card being dragged for hand-sorting (board-wide). Identifies the
    /// drag payload once the drop delegate reports which card it is over;
    /// reordering is always within the origin column and never changes a
    /// session's status.
    @Binding var draggingID: UUID?

    private var columnSessions: [Session] {
        PerfLog.measure("KanbanColumnView.columnSessions", "\(column.title) of \(store.sessions.count) sessions") {
            store.getSessionsForColumn(column, board: board)
        }
    }

    private var filteredSessions: [Session] {
        scope.apply(to: columnSessions)
    }

    /// Resolved once per render rather than per card. Empty unless the board
    /// is mixing projects (`showProjectName`).
    private var projectNames: [UUID: String] {
        guard showProjectName else { return [:] }
        return filteredSessions.reduce(into: [:]) { map, session in
            map[session.id] = store.project(for: session)?.name
        }
    }

    private var accentColor: Color {
        StatusPresentation.color(for: column.statusFilter)
    }

    var body: some View {
        let _ = PerfLog.bump("KanbanColumnView.body", column.title)
        VStack(alignment: .leading, spacing: 10) {
            columnHeader

            if filteredSessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(filteredSessions) { session in
                            KanbanCard(
                                session: session,
                                projectName: projectNames[session.id],
                                diffStatStore: store.diffStatStore,
                                activityStore: activityStore,
                                onOpen: { openSession(session.id) },
                                onDelete: {},
                                onRestart: { store.restartSession(sessionID: session.id) }
                            )
                            // While this card is the one in flight, hide its
                            // body and leave a drop-slot outline the same size
                            // in its place — the floating drag preview is the
                            // only "card" on screen, and the outline slides to
                            // wherever the release will land.
                            .opacity(draggingID == session.id ? 0 : 1)
                            .overlay {
                                if draggingID == session.id {
                                    RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous)
                                        .fill(FlotillaColors.accent.opacity(0.05))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous)
                                                .strokeBorder(
                                                    FlotillaColors.accent.opacity(0.35),
                                                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                                                )
                                        )
                                        .transition(.opacity)
                                }
                            }
                            .matchedGeometryEffect(id: session.id, in: cardMotion)
                            .transition(.scale(scale: 0.92).combined(with: .opacity))
                            .onDrag {
                                draggingID = session.id
                                return NSItemProvider(object: session.id.uuidString as NSString)
                            } preview: {
                                KanbanDragPreview(
                                    session: session,
                                    projectName: projectNames[session.id],
                                    width: width
                                )
                            }
                            .onDrop(of: [.text], delegate: KanbanReorderDropDelegate(
                                onEnter: { reorder(dragged: draggingID, over: session.id) },
                                onPerform: endDrag
                            ))
                        }

                        // Landing zone past the last card, so a card can be
                        // dragged to the bottom of its column.
                        Color.clear
                            .frame(height: 28)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onDrop(of: [.text], delegate: KanbanReorderDropDelegate(
                                onEnter: { reorder(dragged: draggingID, toEnd: true) },
                                onPerform: endDrag
                            ))
                    }
                    .padding(.bottom, 8)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous)
                .fill(FlotillaColors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous)
                .strokeBorder(FlotillaColors.separator.opacity(0.8), lineWidth: 1)
        )
    }

    /// Live hand-sort: as the drag hovers a card, move the dragged card past
    /// it and persist immediately, so the stack reflows under the cursor.
    /// The dragged card lands *after* the target when travelling down and
    /// *before* it when travelling up, so it swaps with a neighbour the
    /// moment it's hovered rather than needing to overshoot. A no-op unless
    /// the drag started in this column — dragging onto a different status
    /// column changes nothing, because status is the session's to change,
    /// not the user's.
    private func reorder(dragged draggedID: UUID?, over targetID: UUID? = nil, toEnd: Bool = false) {
        let original = filteredSessions.map(\.id)
        guard let draggedID, let from = original.firstIndex(of: draggedID) else { return }

        var ids = original
        ids.remove(at: from)

        let insertAt: Int
        if toEnd {
            insertAt = ids.count
        } else if let targetID, targetID != draggedID,
                  let targetInOriginal = original.firstIndex(of: targetID),
                  let targetInRemaining = ids.firstIndex(of: targetID) {
            insertAt = from < targetInOriginal ? targetInRemaining + 1 : targetInRemaining
        } else {
            return
        }
        ids.insert(draggedID, at: min(insertAt, ids.count))
        guard ids != original else { return }

        var order = board.cardOrder
        for (index, id) in ids.enumerated() {
            order[id.uuidString] = index
        }
        withAnimation(FlotillaMotion.spring.curve) {
            store.updateKanbanCardOrder(order)
        }
    }

    /// Ends a drag: accepts it only when the card came from this column (so a
    /// cross-column drop snaps back). The drop-slot outline cross-fades to the
    /// real card rather than hard-swapping, so it blends with the system's
    /// drag-image dismissal instead of briefly showing two crisp cards.
    private func endDrag() -> Bool {
        guard let dropped = draggingID else { return false }
        let accepted = filteredSessions.contains { $0.id == dropped }
        withAnimation(.easeOut(duration: 0.18)) { draggingID = nil }
        return accepted
    }

    private var columnHeader: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(accentColor)
                .frame(width: 7, height: 7)
                .opacity(column.statusFilter == nil ? 0.5 : 1)

            Text(column.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FlotillaColors.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text("\(filteredSessions.count)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(filteredSessions.isEmpty ? FlotillaColors.textTertiary : accentColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(accentColor.opacity(filteredSessions.isEmpty ? 0.06 : 0.14))
                )
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
        .accessibilityIdentifier("KanbanColumn-\(column.title)-Header")
    }

    /// A quiet, short placeholder rather than an empty full-height well:
    /// four of five columns are usually empty, and stretching each of them
    /// to the window height is what made the board read as mostly void.
    private var emptyState: some View {
        Text("Nothing here")
            .font(.system(size: 11))
            .foregroundStyle(FlotillaColors.textTertiary.opacity(0.7))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                    .strokeBorder(
                        FlotillaColors.separator.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
            )
    }
}

/// Per-card reorder target. `dropEntered` drives the live hover shuffle;
/// `performDrop` commits it. `.move` keeps the cursor showing a reorder,
/// not a copy.
private struct KanbanReorderDropDelegate: DropDelegate {
    let onEnter: () -> Void
    let onPerform: () -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        onEnter()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        onPerform()
    }
}

struct KanbanDragPreview: View {
    let session: Session
    var projectName: String? = nil
    let width: CGFloat

    var body: some View {
        KanbanCard(
            session: session,
            projectName: projectName,
            diffStatStore: nil,
            activityStore: nil,
            onOpen: {},
            onDelete: {},
            onRestart: {}
        )
        .frame(width: width - 20)
    }
}
