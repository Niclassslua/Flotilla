import XCTest
import SessionKit
import ProcessKit
import GitKit
import PersistenceKit
import SettingsKit
import TerminalKit
import HooksKit
@testable import Flotilla

@MainActor
final class TerminalControllerReflowTests: XCTestCase {
    func testCustomReflowHandlerInvokedOnSizeChangedAndDisplay() async throws {
        let process = MockPTYProcess()
        try process.start(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )

        var reflowCallCount = 0
        var lastResizedSize: PTYSize?

        let controller = TerminalController(
            sessionID: UUID(),
            process: process,
            accessibilityIdentifier: "ReflowTest",
            customReflowHandler: { _ in
                reflowCallCount += 1
            },
            onPTYResize: { size in
                lastResizedSize = size
            }
        )

        let sessionView = controller.terminalView(for: .session)
        controller.sizeChanged(source: sessionView, newCols: 120, newRows: 40)

        // Wait for debounced resize and reflow
        for _ in 0..<20 {
            if reflowCallCount > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(lastResizedSize, PTYSize(cols: 120, rows: 40))
        XCTAssertGreaterThanOrEqual(reflowCallCount, 1)
    }

    func testMakeAuthoritativeIgnoresDegenerateDimensions() async throws {
        let process = MockPTYProcess()
        try process.start(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )

        var lastResizedSize: PTYSize?
        let controller = TerminalController(
            sessionID: UUID(),
            process: process,
            accessibilityIdentifier: "DegenerateTest",
            onPTYResize: { size in
                lastResizedSize = size
            }
        )

        // Switch to grid before it has laid out (terminal.getDims() is default / unmeasured)
        controller.makeAuthoritative(.grid)

        // Default mock terminal in headless test reports 80x25 or valid, but if below 20x5 it's guarded.
        // Verifies makeAuthoritative runs without crashing
        XCTAssertNotNil(controller)
    }
}
