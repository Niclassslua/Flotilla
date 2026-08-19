import XCTest
import SessionKit
import ProcessKit
import GitKit
import PersistenceKit
import SettingsKit
@testable import Flotilla

private final class RecordingProcessFactory: PTYProcessCreating, @unchecked Sendable {
    private(set) var processes: [MockPTYProcess] = []

    func makeProcess() -> any PTYProcessProtocol {
        let process = MockPTYProcess()
        process.echoInputToOutput = true
        processes.append(process)
        return process
    }
}

@MainActor
final class KanbanPersistenceTests: XCTestCase {
    func testKanbanBoardRoundTrip() throws {
        let repo = try GRDBSessionRepository()

        let board = KanbanBoard(
            projectID: UUID(),
            name: "Test Board",
            columnMode: .status,
            customColumns: KanbanColumn.defaultStatusColumns()
        )
        try repo.saveKanbanBoard(board)

        let loaded = try repo.loadKanbanBoard(id: board.id)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.name, "Test Board")
        XCTAssertEqual(loaded?.columnMode, .status)
        XCTAssertEqual(loaded?.customColumns.count, 6)
    }

    func testKanbanBoardWithCustomColumns() throws {
        let repo = try GRDBSessionRepository()

        let customColumns = [
            KanbanColumn(title: "To Do", order: 0, color: "#F55C29"),
            KanbanColumn(title: "In Progress", order: 1, color: "#42B8EB"),
            KanbanColumn(title: "Done", order: 2, color: "#30C7A3")
        ]
        let board = KanbanBoard(
            projectID: UUID(),
            name: "Custom Board",
            columnMode: .custom,
            customColumns: customColumns
        )
        try repo.saveKanbanBoard(board)

        let loaded = try repo.loadKanbanBoard(id: board.id)
        XCTAssertEqual(loaded?.columnMode, .custom)
        XCTAssertEqual(loaded?.customColumns.count, 3)
        XCTAssertEqual(loaded?.customColumns[0].title, "To Do")
        XCTAssertEqual(loaded?.customColumns[1].title, "In Progress")
        XCTAssertEqual(loaded?.customColumns[2].title, "Done")
    }

    func testKanbanCardOrderPersists() throws {
        let repo = try GRDBSessionRepository()

        let session1 = UUID()
        let session2 = UUID()
        let cardOrder = [session1.uuidString: 0, session2.uuidString: 1]

        let board = KanbanBoard(
            projectID: nil,
            name: "Global",
            columnMode: .custom,
            cardOrder: cardOrder
        )
        try repo.saveKanbanBoard(board)

        let loaded = try repo.loadKanbanBoard(id: board.id)
        XCTAssertEqual(loaded?.cardOrder[session1.uuidString], 0)
        XCTAssertEqual(loaded?.cardOrder[session2.uuidString], 1)
    }

    func testLoadKanbanBoardsReturnsAll() throws {
        let repo = try GRDBSessionRepository()

        let board1 = KanbanBoard(projectID: UUID(), name: "Board 1")
        let board2 = KanbanBoard(projectID: UUID(), name: "Board 2")
        let board3 = KanbanBoard(projectID: nil, name: "Global")
        try repo.saveKanbanBoard(board1)
        try repo.saveKanbanBoard(board2)
        try repo.saveKanbanBoard(board3)

        let boards = try repo.loadKanbanBoards()
        XCTAssertEqual(boards.count, 3)
    }

    func testGetOrCreateDefaultKanbanBoardForProjectAndGlobal() throws {
        let repo = try GRDBSessionRepository()
        let projectID = UUID()

        let board = try repo.getOrCreateDefaultKanbanBoard(forProject: projectID, name: "Project Board")
        XCTAssertEqual(board.projectID, projectID)
        XCTAssertEqual(board.name, "Project Board")
        XCTAssertEqual(board.columnMode, .status)
        XCTAssertEqual(board.customColumns.count, 6)

        // Second call should return same board
        let board2 = try repo.getOrCreateDefaultKanbanBoard(forProject: projectID, name: "Project Board")
        XCTAssertEqual(board2.id, board.id)

        // Global board creation
        let globalBoard = try repo.getOrCreateDefaultKanbanBoard(forProject: nil, name: "All Projects")
        XCTAssertNil(globalBoard.projectID)
        XCTAssertEqual(globalBoard.name, "All Projects")
        XCTAssertEqual(globalBoard.columnMode, .status)
        XCTAssertEqual(globalBoard.customColumns.count, 6)
    }

    func testDeleteKanbanBoard() throws {
        let repo = try GRDBSessionRepository()

        let board = KanbanBoard(projectID: UUID(), name: "To Delete")
        try repo.saveKanbanBoard(board)
        try repo.deleteKanbanBoard(id: board.id)

        let loaded = try repo.loadKanbanBoard(id: board.id)
        XCTAssertNil(loaded)
    }

    func testSessionWithKanbanFieldsRoundTrip() throws {
        let repo = try GRDBSessionRepository()

        let columnID = UUID()
        let workflowStage = WorkflowStage.inProgress

        let session = Session(
            title: "Kanban Session",
            goal: "Test kanban fields",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working,
            kanbanColumnID: columnID,
            workflowStage: workflowStage
        )
        try repo.save(session)

        let (_, sessions) = try repo.loadAll()
        let loaded = try XCTUnwrap(sessions.first)
        XCTAssertEqual(loaded.kanbanColumnID, columnID)
        XCTAssertEqual(loaded.workflowStage, workflowStage)
    }
}

@MainActor
final class KanbanAppStoreTests: XCTestCase {
    private func makeStore() -> (AppStore, RecordingProcessFactory) {
        let repository = try! GRDBSessionRepository()
        let factory = RecordingProcessFactory()
        let store = AppStore(
            repository: repository,
            gitService: MockGitService(),
            processManager: SessionProcessManager(
                locator: FixedExecutableLocator(executable: URL(fileURLWithPath: "/usr/bin/env")),
                processFactory: factory
            ),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") }
        )
        return (store, factory)
    }

    func testKanbanBoardsLoadedOnInit() throws {
        let (store, _) = makeStore()

        XCTAssertFalse(store.kanbanBoards.isEmpty)
        XCTAssertNotNil(store.selectedKanbanBoardID)
        XCTAssertNotNil(store.selectedKanbanBoard)

        let globalBoard = store.kanbanBoards.first { $0.projectID == nil }
        XCTAssertNotNil(globalBoard)
        XCTAssertEqual(globalBoard?.name, "All Projects")
        XCTAssertEqual(globalBoard?.columnMode, .status)
    }

    func testSelectKanbanBoard() throws {
        let (store, _) = makeStore()

        let firstBoard = store.kanbanBoards[0]
        store.selectKanbanBoard(firstBoard.id)
        XCTAssertEqual(store.selectedKanbanBoardID, firstBoard.id)
        XCTAssertEqual(store.selectedKanbanBoard?.id, firstBoard.id)
    }

    func testSelectKanbanBoardByProject() async throws {
        let (store, factory) = makeStore()

        // Add a project by creating a session with it
        await store.createSession(
            title: "Project Session",
            goal: "Goal",
            agent: .claudeCode,
            projectFolder: URL(fileURLWithPath: "/tmp/test"),
            checkoutMode: .mainCheckout
        )

        // Reload to pick up the new project board
        store.loadKanbanBoards()

        let project = store.projects.first { $0.name == "test" }
        XCTAssertNotNil(project)

        let projectBoard = store.kanbanBoards.first { $0.projectID == project?.id }
        XCTAssertNotNil(projectBoard)

        store.selectKanbanBoard(forProject: project!.id)
        XCTAssertEqual(store.selectedKanbanBoardID, projectBoard?.id)
    }

    func testUpdateKanbanBoardColumnMode() throws {
        let (store, _) = makeStore()

        store.updateKanbanBoardColumnMode(.agents)
        let board = try XCTUnwrap(store.selectedKanbanBoard)
        XCTAssertEqual(board.columnMode, .agents)
        XCTAssertEqual(board.customColumns.count, 4)
        XCTAssertEqual(board.customColumns[0].agentFilter, .claudeCode)
        XCTAssertEqual(board.customColumns[1].agentFilter, .codexCLI)
        XCTAssertEqual(board.customColumns[2].agentFilter, .openCode)
        XCTAssertEqual(board.customColumns[3].agentFilter, .antigravity)
    }

    func testUpdateKanbanBoardWorkflowMode() throws {
        let (store, _) = makeStore()

        store.updateKanbanBoardColumnMode(.workflow)
        let board = try XCTUnwrap(store.selectedKanbanBoard)
        XCTAssertEqual(board.columnMode, .workflow)
        XCTAssertEqual(board.customColumns.count, 4)
        XCTAssertEqual(board.customColumns[0].workflowStageFilter, .backlog)
        XCTAssertEqual(board.customColumns[1].workflowStageFilter, .inProgress)
        XCTAssertEqual(board.customColumns[2].workflowStageFilter, .review)
        XCTAssertEqual(board.customColumns[3].workflowStageFilter, .merged)
    }

    func testGetColumnsForBoardStatusMode() throws {
        let (store, _) = makeStore()
        let board = try XCTUnwrap(store.selectedKanbanBoard)

        let columns = store.getColumnsForBoard(board)
        XCTAssertEqual(columns.count, 6)
        XCTAssertEqual(columns[0].title, "Working")
        XCTAssertEqual(columns[0].statusFilter, .working)
        XCTAssertEqual(columns[5].title, "Crashed")
    }

    func testGetColumnsForBoardAgentsMode() throws {
        let (store, _) = makeStore()
        store.updateKanbanBoardColumnMode(.agents)
        let board = try XCTUnwrap(store.selectedKanbanBoard)

        let columns = store.getColumnsForBoard(board)
        XCTAssertEqual(columns.count, 4)
        XCTAssertEqual(columns[0].agentFilter, .claudeCode)
        XCTAssertEqual(columns[1].agentFilter, .codexCLI)
        XCTAssertEqual(columns[2].agentFilter, .openCode)
        XCTAssertEqual(columns[3].agentFilter, .antigravity)
    }

    func testMoveSessionToStatus() async throws {
        let (store, factory) = makeStore()

        await store.createSession(
            title: "Test Session",
            goal: "Goal",
            agent: .claudeCode,
            projectFolder: nil,
            checkoutMode: .mainCheckout
        )
        let session = store.sessions.first { $0.title == "Test Session" }
        XCTAssertNotNil(session)

        store.moveSessionToStatus(sessionID: session!.id, status: .working)

        let updated = store.sessions.first { $0.id == session!.id }
        XCTAssertEqual(updated?.status, .working)
    }

    func testMoveSessionToAgent() async throws {
        let (store, factory) = makeStore()

        await store.createSession(
            title: "Test Session",
            goal: "Goal",
            agent: .claudeCode,
            projectFolder: nil,
            checkoutMode: .mainCheckout
        )
        let session = store.sessions.first { $0.title == "Test Session" }
        XCTAssertNotNil(session)

        let initialProcessCount = factory.processes.count
        store.moveSessionToAgent(sessionID: session!.id, agent: .codexCLI)

        let updated = store.sessions.first { $0.id == session!.id }
        XCTAssertEqual(updated?.agent, .codexCLI)
        // Should restart with new agent
        XCTAssertEqual(factory.processes.count, initialProcessCount + 1)
    }

    func testMoveSessionToWorkflowStage() async throws {
        let (store, _) = makeStore()

        await store.createSession(
            title: "Test Session",
            goal: "Goal",
            agent: .claudeCode,
            projectFolder: nil,
            checkoutMode: .mainCheckout
        )
        let session = store.sessions.first { $0.title == "Test Session" }
        XCTAssertNotNil(session)

        store.moveSessionToWorkflowStage(sessionID: session!.id, stage: .inProgress)

        let updated = store.sessions.first { $0.id == session!.id }
        XCTAssertEqual(updated?.workflowStage, .inProgress)
    }

    func testMoveSessionToColumnCustomMode() async throws {
        let (store, _) = makeStore()
        store.updateKanbanBoardColumnMode(.custom)
        var board = try XCTUnwrap(store.selectedKanbanBoard)
        // Update the board's custom columns
        board.customColumns = [
            KanbanColumn(title: "To Do", order: 0),
            KanbanColumn(title: "Doing", order: 1)
        ]
        store.saveKanbanBoard(board)

        await store.createSession(
            title: "Test Session",
            goal: "Goal",
            agent: .claudeCode,
            projectFolder: nil,
            checkoutMode: .mainCheckout
        )
        let session = store.sessions.first { $0.title == "Test Session" }
        XCTAssertNotNil(session)

        // Need to get the updated board
        let currentBoard = try XCTUnwrap(store.selectedKanbanBoard)
        let targetColumn = currentBoard.customColumns[1]
        store.moveSessionToColumn(sessionID: session!.id, columnID: targetColumn.id)

        let updated = store.sessions.first { $0.id == session!.id }
        XCTAssertEqual(updated?.kanbanColumnID, targetColumn.id)
        // Re-fetch board to get updated cardOrder
        let updatedBoard = try XCTUnwrap(store.selectedKanbanBoard)
        XCTAssertEqual(updatedBoard.cardOrder[session!.id.uuidString], 0)
    }

    func testGetSessionsForColumnStatusMode() async throws {
        let (store, factory) = makeStore()

        await store.createSession(
            title: "Working Session",
            goal: "Goal",
            agent: .claudeCode,
            projectFolder: nil,
            checkoutMode: .mainCheckout
        )
        let session1 = store.sessions.first { $0.title == "Working Session" }!

        // Create another session that will be idle (need to manipulate status)
        await store.createSession(
            title: "Idle Session",
            goal: "Goal",
            agent: .claudeCode,
            projectFolder: nil,
            checkoutMode: .mainCheckout
        )
        let session2 = store.sessions.first { $0.title == "Idle Session" }!
        store.moveSessionToStatus(sessionID: session2.id, status: .idle)

        let board = try XCTUnwrap(store.selectedKanbanBoard)
        let workingColumn = board.customColumns.first { $0.statusFilter == .working }!
        let workingSessions = store.getSessionsForColumn(workingColumn, board: board)
        XCTAssertEqual(workingSessions.count, 1)
        XCTAssertEqual(workingSessions.first?.id, session1.id)

        let idleColumn = board.customColumns.first { $0.statusFilter == .idle }!
        let idleSessions = store.getSessionsForColumn(idleColumn, board: board)
        XCTAssertEqual(idleSessions.count, 1)
        XCTAssertEqual(idleSessions.first?.id, session2.id)
    }

    func testGetSessionsForColumnAgentsMode() async throws {
        let (store, factory) = makeStore()

        await store.createSession(
            title: "Claude Session",
            goal: "Goal",
            agent: .claudeCode,
            projectFolder: nil,
            checkoutMode: .mainCheckout
        )
        let session1 = store.sessions.first { $0.title == "Claude Session" }!

        await store.createSession(
            title: "Codex Session",
            goal: "Goal",
            agent: .codexCLI,
            projectFolder: nil,
            checkoutMode: .mainCheckout
        )
        let session2 = store.sessions.first { $0.title == "Codex Session" }!

        store.updateKanbanBoardColumnMode(.agents)
        let board = try XCTUnwrap(store.selectedKanbanBoard)
        let claudeColumn = board.customColumns.first { $0.agentFilter == .claudeCode }!
        let claudeSessions = store.getSessionsForColumn(claudeColumn, board: board)
        XCTAssertEqual(claudeSessions.count, 1)
        XCTAssertEqual(claudeSessions.first?.id, session1.id)

        let codexColumn = board.customColumns.first { $0.agentFilter == .codexCLI }!
        let codexSessions = store.getSessionsForColumn(codexColumn, board: board)
        XCTAssertEqual(codexSessions.count, 1)
        XCTAssertEqual(codexSessions.first?.id, session2.id)
    }

    func testGetSessionsForColumnFiltersByProject() async throws {
        let (store, factory) = makeStore()

        // Create a project and session in it
        await store.createSession(
            title: "In Project",
            goal: "Goal",
            agent: .claudeCode,
            projectFolder: URL(fileURLWithPath: "/tmp/test"),
            checkoutMode: .mainCheckout
        )
        let sessionInProject = store.sessions.first { $0.title == "In Project" }!

        await store.createSession(
            title: "General",
            goal: "Goal",
            agent: .claudeCode,
            projectFolder: nil,
            checkoutMode: .mainCheckout
        )
        let sessionGeneral = store.sessions.first { $0.title == "General" }!

        // Reload to pick up the new project board
        store.loadKanbanBoards()

        // Select the project board
        let project = store.projects.first { $0.name == "test" }
        XCTAssertNotNil(project)
        let projectBoard = store.kanbanBoards.first { $0.projectID == project?.id }
        XCTAssertNotNil(projectBoard)
        store.selectKanbanBoard(projectBoard!.id)

        let board = try XCTUnwrap(store.selectedKanbanBoard)
        let workingColumn = board.customColumns.first { $0.statusFilter == .working }!
        let projectSessions = store.getSessionsForColumn(workingColumn, board: board)
        XCTAssertEqual(projectSessions.count, 1)
        XCTAssertEqual(projectSessions.first?.id, sessionInProject.id)
    }

    func testCardOrderUpdatedOnMove() async throws {
        let (store, _) = makeStore()
        store.updateKanbanBoardColumnMode(.custom)

        // Set up custom columns for testing
        var board = try XCTUnwrap(store.selectedKanbanBoard)
        board.customColumns = [
            KanbanColumn(title: "To Do", order: 0),
            KanbanColumn(title: "Doing", order: 1)
        ]
        store.saveKanbanBoard(board)

        await store.createSession(
            title: "Session 1",
            goal: "Goal",
            agent: .claudeCode,
            projectFolder: nil,
            checkoutMode: .mainCheckout
        )
        let session1 = store.sessions.first { $0.title == "Session 1" }!

        await store.createSession(
            title: "Session 2",
            goal: "Goal",
            agent: .claudeCode,
            projectFolder: nil,
            checkoutMode: .mainCheckout
        )
        let session2 = store.sessions.first { $0.title == "Session 2" }!

        let board2 = try XCTUnwrap(store.selectedKanbanBoard)
        let doingColumn = board2.customColumns.first { $0.title == "Doing" }!
        store.moveSessionToColumn(sessionID: session1.id, columnID: doingColumn.id)
        store.moveSessionToColumn(sessionID: session2.id, columnID: doingColumn.id)

        // Re-fetch board to get updated cardOrder
        let updatedBoard = try XCTUnwrap(store.selectedKanbanBoard)
        XCTAssertEqual(updatedBoard.cardOrder[session1.id.uuidString], 0)
        XCTAssertEqual(updatedBoard.cardOrder[session2.id.uuidString], 1)
    }
}

// Helper types from AppLayerTests
private struct FixedExecutableLocator: ExecutableLocating {
    let executable: URL?
    var tmuxExecutable: URL? = nil

    func locate(_ name: String) -> URL? {
        name == "tmux" ? tmuxExecutable : executable
    }
}