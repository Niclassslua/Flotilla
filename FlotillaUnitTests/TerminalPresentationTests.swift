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
final class TerminalPresentationTests: XCTestCase {
    func testSessionAndGridUseIndependentRenderersWithSharedOutput() async throws {
        let process = MockPTYProcess()
        try process.start(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 120, rows: 30)
        )
        let receivedOutput = expectation(description: "controller receives PTY output")
        let controller = TerminalController(
            sessionID: UUID(),
            process: process,
            accessibilityIdentifier: "TerminalView-Test",
            multilineNewlineSequence: Data([0x0A]),
            outputHandler: { _ in receivedOutput.fulfill() }
        )

        let sessionView = controller.terminalView(for: .session)
        let gridView = controller.terminalView(for: .grid)
        XCTAssertFalse(sessionView === gridView)

        process.simulateOutput("shared-renderer-output")
        await fulfillment(of: [receivedOutput], timeout: 2)

        let sessionText = controller.bufferText(for: .session)
        let gridText = controller.bufferText(for: .grid)
        XCTAssertTrue(sessionText.contains("shared-renderer-output"))
        XCTAssertTrue(gridText.contains("shared-renderer-output"))

        controller.sendMultilineNewline()
        XCTAssertEqual(process.sentInput.last, Data([0x0A]))
    }

    /// Handoff keeps the session id (and thus the cached controller). The
    /// Shift+Enter sequence must follow the new agent (#71).
    func testUpdateHandlersRefreshesMultilineNewlineSequence() throws {
        let process = MockPTYProcess()
        try process.start(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 120, rows: 30)
        )
        let claudeSequence = Data([0x1B, 0x0D])
        let codexSequence = Data([0x0A])
        let controller = TerminalController(
            sessionID: UUID(),
            process: process,
            accessibilityIdentifier: "TerminalView-Handoff",
            multilineNewlineSequence: claudeSequence
        )

        controller.sendMultilineNewline()
        XCTAssertEqual(process.sentInput.last, claudeSequence)

        controller.updateHandlers(multilineNewlineSequence: codexSequence)
        controller.sendMultilineNewline()
        XCTAssertEqual(process.sentInput.last, codexSequence)
        XCTAssertEqual(controller.multilineNewlineSequence, codexSequence)
    }
}
