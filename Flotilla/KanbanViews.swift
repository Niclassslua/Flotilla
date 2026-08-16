import SwiftUI
import SessionKit
import DesignSystem
import TerminalKit
import ProcessKit
import UniformTypeIdentifiers

struct KanbanTabView: View {
    @Bindable var store: AppStore
    let terminalManager: TerminalManager
    let openSession: (UUID) -> Void

    @State private var showingColumnModePicker = false
    @State private var dragOverColumnID: UUID?
    @State private var showingNewBoardSheet = false
    @State private var newBoardName = ""
    
    var body: some View {
        let _ = PerfLog.bump("KanbanTabView.body")
        VStack(spacing: 0) {
            kanbanToolbar
            Divider()

            if let board = store.selectedKanbanBoard {
                KanbanBoardView(
                    store: store,
                    board: board,
                    terminalManager: terminalManager,
                    openSession: openSession,
                    dragOverColumnID: $dragOverColumnID
                )
            } else {
                ContentUnavailableView(
                    "No Board",
                    systemImage: "square.grid.2x2",
                    description: Text("Select or create a Kanban board")
                )
            }
        }
        .background(FlotillaColors().canvas)
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

    private var kanbanToolbar: some View {
        HStack(spacing: 12) {
            Label("Kanban", systemImage: "square.grid.2x2.fill")
                .font(.headline)
            
            if let board = store.selectedKanbanBoard {
                Text(board.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Picker("Column Mode", selection: Binding(
                get: { store.selectedKanbanBoard?.columnMode ?? .status },
                set: { mode in
                    store.updateKanbanBoardColumnMode(mode)
                }
            )) {
                ForEach(KanbanColumnMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
            .labelsHidden()
            
            Menu {
                ForEach(store.kanbanBoards) { board in
                    Button(board.name) {
                        store.selectKanbanBoard(board.id)
                    }
                }
                Divider()
                Button("New Board…") {
                    showingNewBoardSheet = true
                }
            } label: {
                Label("Boards", systemImage: "sidebar.left")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(FlotillaColors().surface)
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
        .background(FlotillaColors().canvas)
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

struct KanbanBoardView: View {
    @Bindable var store: AppStore
    let board: KanbanBoard
    let terminalManager: TerminalManager
    let openSession: (UUID) -> Void
    @Binding var dragOverColumnID: UUID?
    
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
                        onDragExit: { if dragOverColumnID == column.id { dragOverColumnID = nil } }
                    )
                }
                
                // Add column button for custom mode
                if board.columnMode == .custom {
                    AddColumnButton(board: board, store: store)
                }
            }
            .padding(12)
            .padding(.vertical, 8)
        }
        .background(FlotillaColors().canvas)
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
    
    private var columnSessions: [Session] {
        PerfLog.measure("KanbanColumnView.columnSessions", "\(column.title) of \(store.sessions.count) sessions") {
            store.getSessionsForColumn(column, board: board)
        }
    }

    var body: some View {
        let _ = PerfLog.bump("KanbanColumnView.body", column.title)
        VStack(alignment: .leading, spacing: 8) {
            columnHeader
            
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(columnSessions) { session in
                        KanbanCardView(
                            store: store,
                            board: board,
                            session: session,
                            terminalManager: terminalManager,
                            openSession: openSession
                        )
                        .draggable(session.id.uuidString) {
                            KanbanDragPreview(session: session)
                        }
                    }
                    
                    // Drop zone for empty column
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
                .fill(isDragTarget ? FlotillaColors().accent.opacity(0.1) : FlotillaColors().surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                .strokeBorder(isDragTarget ? FlotillaColors().accent : FlotillaColors().separator, lineWidth: isDragTarget ? 2 : 1)
        )
        .onDrop(of: [.text], isTargeted: Binding(
            get: { isDragTarget },
            set: { _ in }
        )) { providers in
            handleDrop(providers: providers)
        }
    }
    
    private var columnHeader: some View {
        HStack(spacing: 8) {
            // Status badge for status-mode columns
            if board.columnMode == .status, let status = column.statusFilter {
                StatusBadge(status, variant: .compact)
            }
            
            Text(column.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            
            Text("\(columnSessions.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(FlotillaColors().surfaceElevated, in: Capsule())
            
            Spacer()
            
            if board.columnMode == .custom {
                Menu {
                    Button("Edit") {
                        // TODO: Edit column
                    }
                    Button("Delete", role: .destructive) {
                        // TODO: Delete column
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        let transferType = UTType.text.identifier
        provider.loadItem(forTypeIdentifier: transferType, options: nil) { item, _ in
            guard let data = item as? Data,
                  let sessionIDString = String(data: data, encoding: .utf8),
                  let sessionID = UUID(uuidString: sessionIDString) else { return }
            
            Task { @MainActor in
                switch board.columnMode {
                case .status:
                    if let status = column.statusFilter {
                        store.moveSessionToStatus(sessionID: sessionID, status: status)
                    }
                case .agents:
                    if let agent = column.agentFilter {
                        store.moveSessionToAgent(sessionID: sessionID, agent: agent)
                    }
                case .workflow:
                    if let stage = column.workflowStageFilter {
                        store.moveSessionToWorkflowStage(sessionID: sessionID, stage: stage)
                    }
                case .custom:
                    store.moveSessionToColumn(sessionID: sessionID, columnID: column.id)
                }
            }
        }
        return true
    }
}

struct KanbanCardView: View {
    @Bindable var store: AppStore
    let board: KanbanBoard
    let session: Session
    let terminalManager: TerminalManager
    let openSession: (UUID) -> Void
    
    @State private var terminalPeekController: TerminalController?
    
    private var project: Project? {
        store.project(for: session)
    }
    
    var body: some View {
        let _ = PerfLog.bump("KanbanCardView.body", session.title)
        VStack(alignment: .leading, spacing: 8) {
            cardHeader
            
            // Terminal peek
            if let controller = terminalPeekController {
                TerminalPeekView(controller: controller, session: session)
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                            .strokeBorder(FlotillaColors().separator)
                    )
            } else {
                terminalPlaceholder
            }
            
            // Git diff badge
            if session.worktree != nil {
                gitDiffBadge
            }
            
            // Goal progress
            if !session.goal.isEmpty {
                goalProgress
            }
        }
        .padding(10)
        .background(FlotillaColors().surfaceElevated, in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                .strokeBorder(FlotillaColors().separator)
        )
        .contextMenu {
            cardContextMenu
        }
        .onTapGesture {
            // Single click selects
        }
        .onTapGesture(count: 2) {
            openSession(session.id)
        }
        .task {
            // Deliberately not `onAppear`: attaching a peek can have to build
            // a terminal controller and replay that session's scrollback into
            // a fresh emulator, and doing that for every card inside the
            // layout-switch commit is what made entering the board hang. This
            // yields first, so the board draws and each card's terminal
            // attaches on a later runloop turn.
            await Task.yield()
            setupTerminalPeek()
        }
        .onDisappear {
            terminalPeekController = nil
        }
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
                    
                    if let project {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(project.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            
            Spacer()
            
            // Drag handle
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
        .background(FlotillaColors().terminalCanvas, in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
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
            
// Real diff stats
            if let worktree = session.worktree {
                SessionDiffStatView(session: session, diffStatStore: store.diffStatStore)
            } else {
                Text("±0")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(FlotillaColors().surface, in: Capsule())
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
    
    private var cardContextMenu: some View {
        Group {
            Button("Open Session") {
                openSession(session.id)
            }
            
            Divider()
            
            if board.columnMode == .status {
                ForEach(SessionStatus.allCases) { status in
                    Button(status.rawValue.capitalized) {
                        store.moveSessionToStatus(sessionID: session.id, status: status)
                    }
                }
            } else if board.columnMode == .agents {
                ForEach(AgentKind.allCases) { agent in
                    Button(agent.displayName) {
                        store.moveSessionToAgent(sessionID: session.id, agent: agent)
                    }
                }
            } else if board.columnMode == .workflow {
                ForEach(WorkflowStage.allCases) { stage in
                    Button(stage.rawValue.capitalized) {
                        store.moveSessionToWorkflowStage(sessionID: session.id, stage: stage)
                    }
                }
            }
            
            Divider()
            
            Button("Restart Session") {
                store.restartSession(sessionID: session.id)
            }
            .accessibilityIdentifier("Restart Session")
            
            Button("Delete Session", role: .destructive) {
                Task {
                    await store.deleteSession(sessionID: session.id, deleteWorktree: false)
                }
            }
        }
    }
    
    private func setupTerminalPeek() {
        guard let process = store.process(for: session.id) else {
            PerfLog.event("KanbanCardView.setupTerminalPeek skipped (no process) \(session.title)")
            return
        }

        let isWarm = terminalManager.hasController(for: session.id)
        PerfLog.measure("KanbanCardView.setupTerminalPeek", "\(session.title) warm=\(isWarm)") {
            // Use TerminalManager instead of creating a new TerminalController
            terminalPeekController = terminalManager.controller(
                for: session,
                process: process,
                scrollback: store.scrollback(for: session.id),
                outputHandler: { [weak store] data in
                    store?.appendTerminalOutput(data, toSessionID: session.id)
                },
                inputHandler: {}
            )
        }
    }
}

/// Hosts the card-sized `.peek` renderer for one session. It never touches the
/// `.session` renderer, so the focused workspace keeps its own terminal mounted
/// and measured for its own pane (see `TerminalPresentation.peek`).
struct TerminalPeekView: NSViewRepresentable {
    let controller: TerminalController
    let session: Session

    func makeNSView(context: Context) -> NSView {
        PerfLog.measure("TerminalPeekView.makeNSView", session.title) {
            let container = NSView()
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor(FlotillaColors().terminalCanvas).cgColor
            mount(controller.terminalView(for: .peek), in: container)
            return container
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        PerfLog.bump("TerminalPeekView.updateNSView", session.title)
        let terminalView = controller.terminalView(for: .peek)
        guard terminalView.superview !== nsView else { return }
        mount(terminalView, in: nsView)
    }

    /// Pins the renderer to the card instead of handing it to an `NSScrollView`
    /// as a `documentView`: SwiftTerm sizes its grid from its own frame, and a
    /// document view with no constraints never gets one.
    private func mount(_ terminalView: NSView, in container: NSView) {
        terminalView.removeFromSuperview()
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: container.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

struct KanbanDragPreview: View {
    let session: Session
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(StatusPresentation.color(for: session.status))
                .frame(width: 8, height: 8)
            
            Text(session.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            
            ProviderLogo(agent: session.agent)
                .frame(width: 14, height: 14)
        }
        .padding(10)
        .background(FlotillaColors().surfaceElevated, in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
        .shadow(radius: 8)
    }
}

struct AddColumnButton: View {
    let board: KanbanBoard
    let store: AppStore
    
    var body: some View {
        Button {
            // TODO: Show add column sheet
        } label: {
            VStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.secondary)
                
                Text("Add Column")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 300, height: 120)
            .background(
                RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    .foregroundStyle(FlotillaColors().separator)
            )
        }
        .buttonStyle(.plain)
    }
}