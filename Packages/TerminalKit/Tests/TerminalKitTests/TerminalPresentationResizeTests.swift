import XCTest
import ProcessKit
import TerminalKit

@MainActor
final class TerminalPresentationResizeTests: XCTestCase {
    func testSwitchingToGridRejectsPendingSessionResize() async throws {
        let process = MockPTYProcess()
        let controller = TerminalController(
            sessionID: UUID(), process: process, accessibilityIdentifier: "ResizeSwitch"
        )
        let session = controller.terminalView(for: .session)
        let grid = controller.terminalView(for: .grid)
        let gridSize = PTYSize(cols: 123, rows: 33)

        controller.sizeChanged(source: session, newCols: gridSize.cols, newRows: gridSize.rows)
        XCTAssertEqual(process.lastSize, gridSize)
        controller.sizeChanged(source: session, newCols: 214, newRows: 73)
        controller.makeAuthoritative(.grid)
        // Returning to the existing grid size must also reject the old queued resize.
        controller.sizeChanged(source: grid, newCols: gridSize.cols, newRows: gridSize.rows)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(process.lastSize, gridSize, "An unmounted session must not resize Cursor behind the grid")
    }
}
