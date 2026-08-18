import SwiftUI
import SessionKit
import DesignSystem
import TerminalKit
import UniformTypeIdentifiers

struct KanbanTabView: View {
    @Bindable var store: AppStore
    let terminalManager: TerminalManager
    let openSession: (UUID) -> Void
    var projectFilter: UUID? = nil

    @State private var showingColumnModePicker = false
    @State private var dragOverColumnID: UUID?
    @State private var showingNewBoardSheet = false
    @State private var newBoardName = ""

    var body: some View {
        let _ = PerfLog.bump("KanbanTabView.body")
        VStack(spacing: 0) {
            if let board = store.selectedKanbanBoard {
                KanbanBoardView(
                    store: store,
                    board: board,
                    terminalManager: terminalManager,
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
    let openSession: (UUID) -> Void
    @Binding var dragOverColumnID: UUID?
    var projectFilter: UUID? = nil

    private var columns: [KanbanColumn] {
        PerfLog.measure("KanbanBoardView.columns", "mode=\(board.columnMode)") {
            store.getColumnsForBoard(board)
        }
    }

    var body: some View {
        let _ = PerfLog.bump("KanbanBoardView.body")
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(columns) { column in
                    KanbanColumnView(
                        store: store,
                        board: board,
                        column: column,
                        terminalManager: terminalManager,
                        openSession: openSession,
                        isDragTarget: dragOverColumnID == column.id,
                        onDragEnter: { dragOverColumnID = column.id },
                        onDragExit: { if dragOverColumnID == column.id { dragOverColumnID = nil } },
                        projectFilter: projectFilter
                    )
                }

                if board.columnMode == .custom {
                    AddColumnButton(board: board, store: store)
                }
            }
            .padding(12)
            .padding(.vertical, 8)
        }
        .background(FlotillaColors.canvas)
        .accessibilityIdentifier("KanbanBoard")
    }
}

struct AddColumnButton: View {
    let board: KanbanBoard
    let store: AppStore

    @State private var showingNewColumnSheet = false
    @State private var newColumnName = ""

    var body: some View {
        Button {
            showingNewColumnSheet = true
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus.rectangle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Add Column")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 300, height: 80)
            .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                    .strokeBorder(FlotillaColors.separator.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [8, 4]))
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingNewColumnSheet) {
            NewColumnSheet(
                name: $newColumnName,
                board: board,
                store: store,
                onCancel: {
                    showingNewColumnSheet = false
                    newColumnName = ""
                }
            )
        }
    }
}

struct NewColumnSheet: View {
    @Binding var name: String
    let board: KanbanBoard
    let store: AppStore
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Column")
                        .font(.title3.weight(.semibold))
                    Text("Enter a name for the new column")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Column Name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Column name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            var newBoard = board
                            let column = KanbanColumn(
                                title: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                order: board.customColumns.count
                            )
                            newBoard.customColumns.append(column)
                            newBoard.updatedAt = Date()
                            store.saveKanbanBoard(newBoard)
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
                        var newBoard = board
                        let column = KanbanColumn(
                            title: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            order: board.customColumns.count
                        )
                        newBoard.customColumns.append(column)
                        newBoard.updatedAt = Date()
                        store.saveKanbanBoard(newBoard)
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

struct KanbanColumnView: View {
    @Bindable var store: AppStore
    let board: KanbanBoard
    let column: KanbanColumn
    let terminalManager: TerminalManager
    let openSession: (UUID) -> Void
    let isDragTarget: Bool
    let onDragEnter: () -> Void
    let onDragExit: () -> Void
    var projectFilter: UUID? = nil

    private var columnSessions: [Session] {
        PerfLog.measure("KanbanColumnView.columnSessions", "\(column.title) of \(store.sessions.count) sessions") {
            store.getSessionsForColumn(column, board: board)
        }
    }

    private var filteredSessions: [Session] {
        guard let projectFilter else { return columnSessions }
        return columnSessions.filter { $0.projectID == projectFilter }
    }

    var body: some View {
        let _ = PerfLog.bump("KanbanColumnView.body", column.title)
        VStack(alignment: .leading, spacing: 8) {
            columnHeader

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filteredSessions) { session in
                        SessionCard(
                            session: session,
                            variant: .board,
                            diffStatStore: store.diffStatStore,
                            activityStore: nil,
                            isSelected: false,
                            isActive: false,
                            onTap: { openSession(session.id) },
                            onDelete: {},
                            onRestart: {},
                            onRevealInFinder: {},
                            onCopyPath: {},
                            onCopyBranch: {},
                            terminal: { EmptyView() }
                        )
                        .draggable(session.id.uuidString) {
                            KanbanDragPreview(session: session)
                        }
                    }

                    Color.clear
                        .frame(height: 40)
                        .frame(maxWidth: .infinity)
                        .onDrop(of: [.text], isTargeted: .constant(false)) { providers in
                            handleDrop(providers: providers)
                        }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                .fill(isDragTarget ? FlotillaColors.accent.opacity(0.1) : FlotillaColors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                .strokeBorder(isDragTarget ? FlotillaColors.accent : FlotillaColors.separator, lineWidth: isDragTarget ? 2 : 1)
        )
    }

    private var columnHeader: some View {
        HStack {
            Text(column.title)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Text("\(filteredSessions.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: String.self) { sessionIDString, _ in
            guard let sessionIDString, let sessionID = UUID(uuidString: sessionIDString) else { return }
            Task { @MainActor in
                store.moveSessionToColumn(sessionID: sessionID, columnID: column.id)
            }
        }
        return true
    }
}

extension KanbanColumnMode {
    var displayName: String {
        switch self {
        case .status: "Status"
        case .agents: "Agents"
        case .workflow: "Workflow"
        case .custom: "Custom"
        }
    }
}

struct KanbanDragPreview: View {
    let session: Session

    var body: some View {
        SessionCard(
            session: session,
            variant: .board,
            diffStatStore: nil,
            activityStore: nil,
            isSelected: false,
            isActive: false,
            onTap: {},
            onDelete: {},
            onRestart: {},
            onRevealInFinder: {},
            onCopyPath: {},
            onCopyBranch: {},
            terminal: { EmptyView() }
        )
        .frame(width: 300)
    }
}