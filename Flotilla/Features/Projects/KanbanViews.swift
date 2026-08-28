import SwiftUI
import SessionKit
import DesignSystem
import TerminalKit
import GitKit
import UniformTypeIdentifiers

struct KanbanTabView: View {
    @Bindable var store: AppStore
    let terminalManager: TerminalManager
    var activityStore: SessionActivityStore? = nil
    let openSession: (UUID) -> Void
    var projectFilter: UUID? = nil

    @State private var dragOverColumnID: UUID?
    @State private var showingNewBoardSheet = false
    @State private var newBoardName = ""

    /// `FLOTILLA_DEMO_DATA=1` only: reveals the "Cycle demo card" button that
    /// drives one card through every status and a fresh diff stat, so the
    /// board's state-transition and churn animations can be exercised on
    /// demand instead of waiting for a real agent to change state.
    private let isBoardDemo = ProcessInfo.processInfo.environment["FLOTILLA_DEMO_DATA"] == "1"
    /// `.crashed` may only transition back to `.working` (see
    /// `SessionStatusMachine.canTransition`), so the cycle ends there.
    private let demoStatusCycle: [SessionStatus] = [.working, .waitingForInput, .readyForReview, .crashed]

    var body: some View {
        let _ = PerfLog.bump("KanbanTabView.body")
        VStack(spacing: 0) {
            headerBar
            Divider()
            if let board = store.selectedKanbanBoard {
                KanbanBoardView(
                    store: store,
                    board: board,
                    terminalManager: terminalManager,
                    activityStore: activityStore,
                    openSession: openSession,
                    dragOverColumnID: $dragOverColumnID,
                    projectFilter: projectFilter
                )
            } else {
                ContentUnavailableView(
                    "No Board",
                    systemImage: "square.grid.2x2",
                    description: Text("Select or create a Kanban board")
                )
            }
        }
        .background(FlotillaColors.canvas)
        .sheet(isPresented: $showingNewBoardSheet) {
            NewBoardSheet(
                name: $newBoardName,
                projectID: nil,
                store: store,
                onCancel: {
                    showingNewBoardSheet = false
                    newBoardName = ""
                }
            )
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            if let selected = store.selectedKanbanBoard {
                Menu {
                    ForEach(store.kanbanBoards) { board in
                        Button {
                            store.selectKanbanBoard(board.id)
                        } label: {
                            HStack {
                                Text(board.name)
                                if board.id == selected.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    Divider()
                    Button("New Board…") {
                        showingNewBoardSheet = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2")
                            .foregroundStyle(FlotillaColors.accent)
                        Text(selected.name)
                            .font(.system(size: 13, weight: .semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("BoardPicker")
            }

            Spacer()

            if isBoardDemo {
                Button {
                    cycleDemoCard()
                } label: {
                    Label("Cycle demo card", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("BoardDemoCycleButton")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(FlotillaColors.surface)
    }

    /// Advances demo session 0 to the next status in the cycle and hands the
    /// diff-stat store a fresh `+/−` count, both inside one animation
    /// transaction so the card slides between columns while its churn digits
    /// roll to the new value.
    private func cycleDemoCard() {
        let sessionID = BoardDemoFixtures.sessionID(at: 0)
        let current = store.sessions.first { $0.id == sessionID }?.status
        let nextIndex = current
            .flatMap { demoStatusCycle.firstIndex(of: $0) }
            .map { ($0 + 1) % demoStatusCycle.count } ?? 0
        withAnimation(FlotillaMotion.spring.curve) {
            store.moveSessionToStatus(sessionID: sessionID, status: demoStatusCycle[nextIndex])
            store.diffStatStore.setDemoStat(
                GitDiffStat(additions: Int.random(in: 20...480), deletions: Int.random(in: 0...220)),
                for: sessionID
            )
        }
    }
}

struct NewBoardSheet: View {
    @Binding var name: String
    let projectID: UUID?
    let store: AppStore
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Kanban Board")
                        .font(.title3.weight(.semibold))
                    Text("Enter a name for the new board")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Board Name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Board name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let board = KanbanBoard(projectID: nil, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                            do {
                                try store.createKanbanBoard(board)
                                store.loadKanbanBoards()
                                store.selectKanbanBoard(board.id)
                            } catch {
                                store.lastOperationError = "Failed to create board: \(error.localizedDescription)"
                            }
                            onCancel()
                        }
                    }
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let board = KanbanBoard(projectID: nil, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                        do {
                            try store.createKanbanBoard(board)
                            store.loadKanbanBoards()
                            store.selectKanbanBoard(board.id)
                        } catch {
                            store.lastOperationError = "Failed to create board: \(error.localizedDescription)"
                        }
                        onCancel()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 400)
        .background(FlotillaColors.canvas)
    }
}


struct KanbanBoardView: View {
    @Bindable var store: AppStore
    let board: KanbanBoard
    let terminalManager: TerminalManager
    let activityStore: SessionActivityStore?
    let openSession: (UUID) -> Void
    @Binding var dragOverColumnID: UUID?
    var projectFilter: UUID? = nil

    /// One namespace shared by every column so a card keeps its identity when
    /// its status changes and it moves from one column to another — SwiftUI
    /// then slides it across the gap instead of cross-fading two cards.
    @Namespace private var cardMotion

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
    /// A project-scoped board, or a sidebar project filter, makes every
    /// card's project identical, so the label would be pure noise.
    private var showsProjectName: Bool {
        guard board.projectID == nil, projectFilter == nil else { return false }
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
                            isDragTarget: dragOverColumnID == column.id,
                            onDragTargetChange: { isTargeted in
                                if isTargeted {
                                    dragOverColumnID = column.id
                                } else if dragOverColumnID == column.id {
                                    dragOverColumnID = nil
                                }
                            },
                            projectFilter: projectFilter,
                            showProjectName: showsProjectName,
                            cardMotion: cardMotion
                        )
                    }
                }
                .padding(Self.boardPadding)
                .frame(minHeight: proxy.size.height, alignment: .top)
                .animation(FlotillaMotion.spring.curve, value: renderedSessions)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .background(FlotillaColors.canvas)
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
    let isDragTarget: Bool
    let onDragTargetChange: (Bool) -> Void
    var projectFilter: UUID? = nil
    var showProjectName: Bool = false
    var cardMotion: Namespace.ID

    private var columnSessions: [Session] {
        PerfLog.measure("KanbanColumnView.columnSessions", "\(column.title) of \(store.sessions.count) sessions") {
            store.getSessionsForColumn(column, board: board)
        }
    }

    private var filteredSessions: [Session] {
        guard let projectFilter else { return columnSessions }
        return columnSessions.filter { $0.projectID == projectFilter }
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
                    LazyVStack(spacing: 10) {
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
                            .matchedGeometryEffect(id: session.id, in: cardMotion)
                            .transition(.scale(scale: 0.92).combined(with: .opacity))
                            .draggable(session.id.uuidString) {
                                KanbanDragPreview(
                                    session: session,
                                    projectName: projectNames[session.id],
                                    width: width
                                )
                            }
                        }
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
                .strokeBorder(
                    isDragTarget ? accentColor : FlotillaColors.separator.opacity(0.8),
                    lineWidth: isDragTarget ? 2 : 1
                )
        )
        .background(
            RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous)
                .fill(accentColor.opacity(isDragTarget ? 0.1 : 0))
        )
        .animation(FlotillaMotion.fast.curve, value: isDragTarget)
        // The whole column is the drop target, not a strip at the bottom of
        // the card stack — dropping onto an empty column has to work, and
        // that is exactly the case with no cards to aim at.
        .onDrop(of: [.text], isTargeted: Binding(get: { isDragTarget }, set: onDragTargetChange)) { providers in
            handleDrop(providers: providers)
        }
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

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        // A status column's filter *is* the status the drop should apply.
        // `nil` is the "Unstarted" column, which is not a status a session
        // can be moved back into, so that drop is refused.
        guard let targetStatus = column.statusFilter else { return false }
        _ = provider.loadObject(ofClass: String.self) { sessionIDString, _ in
            guard let sessionIDString, let sessionID = UUID(uuidString: sessionIDString) else { return }
            Task { @MainActor in
                store.moveSessionToStatus(sessionID: sessionID, status: targetStatus)
            }
        }
        return true
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
