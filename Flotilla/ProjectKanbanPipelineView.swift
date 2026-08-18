import SwiftUI
import SessionKit
import DesignSystem

/// Project-Scoped Kanban & Workflow Pipeline (Design 3).
/// Organizes project tasks and agent sessions into visual workflow stages
/// (Backlog → Working → Review → Merged) with quick task creation and session spawning.
struct ProjectKanbanPipelineView: View {
    let project: Project
    @Bindable var store: AppStore
    let terminalManager: TerminalManager
    let openSession: (UUID) -> Void

    @State private var dragOverColumnID: UUID?
    @State private var newTaskTitle = ""
    @State private var isSpawningAgent = false

    private var projectBoard: KanbanBoard? {
        if let board = store.kanbanBoards.first(where: { $0.projectID == project.id }) {
            return board
        }
        return store.selectedKanbanBoard
    }

    var body: some View {
        VStack(spacing: 0) {
            topPipelineBar
            Divider()

            if let board = projectBoard {
                KanbanBoardView(
                    store: store,
                    board: board,
                    terminalManager: terminalManager,
                    openSession: openSession,
                    dragOverColumnID: $dragOverColumnID,
                    projectFilter: project.id
                )
            } else {
                ContentUnavailableView(
                    "No Kanban Board",
                    systemImage: "square.grid.2x2",
                    description: Text("Initializing project pipeline…")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(FlotillaColors.canvas)
        .task(id: project.id) {
            store.selectKanbanBoard(forProject: project.id)
            if store.selectedKanbanBoard == nil {
                store.loadKanbanBoards()
                store.selectKanbanBoard(forProject: project.id)
            }
        }
    }

    // MARK: - Top Pipeline Bar

    private var topPipelineBar: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            if let board = projectBoard {
                Picker("Column Mode", selection: Binding(
                    get: { board.columnMode },
                    set: { newMode in
                        var updated = board
                        updated.columnMode = newMode
                        store.saveKanbanBoard(updated)
                    }
                )) {
                    Text("Workflow Stages").tag(KanbanColumnMode.workflow)
                    Text("Session Status").tag(KanbanColumnMode.status)
                    Text("By Agent").tag(KanbanColumnMode.agents)
                    Text("Custom Columns").tag(KanbanColumnMode.custom)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
            }

            Spacer()

            HStack(spacing: FlotillaSpacing.small) {
                TextField("Add task to Backlog…", text: $newTaskTitle)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { addTaskToBacklog() }

                Button {
                    addTaskToBacklog()
                } label: {
                    Label("Add Task", systemImage: "plus")
                        .font(FlotillaTypography.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
        .background(FlotillaColors.surfaceElevated)
    }

    private func addTaskToBacklog() {
        let trimmed = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        let session = Session(
            title: trimmed,
            goal: trimmed,
            agent: .claudeCode,
            projectID: project.id,
            workingDirectory: project.rootPath,
            status: .idle,
            workflowStage: .backlog
        )
        
        do {
            try store.repository.save(session)
            store.reload()
            newTaskTitle = ""
        } catch {
            store.lastOperationError = "Failed to add task: \(error.localizedDescription)"
        }
    }
}
