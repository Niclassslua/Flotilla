import Foundation
import Observation
import SessionKit

/// Owns board configuration. Session mutations stay with AppStore.
@Observable @MainActor
final class KanbanStore {
    private(set) var kanbanBoards: [KanbanBoard] = []
    var selectedKanbanBoardID: UUID?
    var lastOperationError: String?
    private let repository: any SessionRepository

    init(repository: any SessionRepository) {
        self.repository = repository
    }

    func create(_ board: KanbanBoard) throws {
        try repository.saveKanbanBoard(board)
    }

    func load(projects: [Project]) {
        do {
            kanbanBoards = try repository.loadKanbanBoards()
            // Ensure we have a global board
            if !kanbanBoards.contains(where: { $0.projectID == nil }) {
                let globalBoard = try repository.getOrCreateDefaultKanbanBoard(forProject: nil, name: "All Projects")
                kanbanBoards.append(globalBoard)
            }
            // Ensure each project has a board
            for project in projects {
                if !kanbanBoards.contains(where: { $0.projectID == project.id }) {
                    let board = try repository.getOrCreateDefaultKanbanBoard(forProject: project.id, name: project.name)
                    kanbanBoards.append(board)
                }
            }
            // Select first board if none selected
            if selectedKanbanBoardID == nil {
                selectedKanbanBoardID = kanbanBoards.first?.id
            }
        } catch {
            lastOperationError = "Kanban boards could not be loaded: \(error.localizedDescription)"
        }
    }

    var selectedKanbanBoard: KanbanBoard? {
        kanbanBoards.first { $0.id == selectedKanbanBoardID }
    }

    func selectKanbanBoard(_ boardID: UUID) {
        selectedKanbanBoardID = boardID
    }

    func selectKanbanBoard(forProject projectID: UUID?) {
        if let board = kanbanBoards.first(where: { $0.projectID == projectID }) {
            selectedKanbanBoardID = board.id
        }
    }

    func save(_ board: KanbanBoard) {
        do {
            try repository.saveKanbanBoard(board)
            if let index = kanbanBoards.firstIndex(where: { $0.id == board.id }) {
                kanbanBoards[index] = board
            }
        } catch {
            lastOperationError = "Kanban board could not be saved: \(error.localizedDescription)"
        }
    }

    func updateKanbanBoardColumnMode(_ mode: KanbanColumnMode) {
        guard var board = selectedKanbanBoard else { return }
        board.columnMode = mode
        // Reset custom columns based on new mode
        switch mode {
        case .status:
            board.customColumns = KanbanColumn.defaultStatusColumns()
        case .agents:
            board.customColumns = KanbanColumn.defaultAgentColumns()
        case .workflow:
            board.customColumns = KanbanColumn.defaultWorkflowColumns()
        case .custom:
            // Keep existing custom columns
            break
        }
        board.updatedAt = Date()
        save(board)
    }

    func updateKanbanCardOrder(_ cardOrder: [String: Int]) {
        guard var board = selectedKanbanBoard else { return }
        board.cardOrder = cardOrder
        board.updatedAt = Date()
        save(board)
    }

    func getColumnsForBoard(_ board: KanbanBoard) -> [KanbanColumn] {
        switch board.columnMode {
        case .status:
            return KanbanColumn.defaultStatusColumns()
        case .agents:
            return KanbanColumn.defaultAgentColumns()
        case .workflow:
            return KanbanColumn.defaultWorkflowColumns()
        case .custom:
            return board.customColumns.sorted { $0.order < $1.order }
        }
    }

    func getSessionsForColumn(_ column: KanbanColumn, board: KanbanBoard, sessions: [Session]) -> [Session] {
        let relevantSessions: [Session]
        if let projectID = board.projectID {
            relevantSessions = sessions.filter { $0.projectID == projectID }
        } else {
            relevantSessions = sessions
        }

        return relevantSessions.filter { session in
            switch board.columnMode {
            case .status:
                return column.statusFilter == session.status
            case .agents:
                return column.agentFilter == session.agent
            case .workflow:
                return column.workflowStageFilter == session.workflowStage
            case .custom:
                return column.id == session.kanbanColumnID
            }
        }.sorted { lhs, rhs in
            let lhsOrder = board.cardOrder[lhs.id.uuidString] ?? 0
            let rhsOrder = board.cardOrder[rhs.id.uuidString] ?? 0
            return lhsOrder < rhsOrder
        }
    }

}
