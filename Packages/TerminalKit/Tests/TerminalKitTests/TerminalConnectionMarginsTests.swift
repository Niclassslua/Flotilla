import XCTest
import ProcessKit
import TerminalKit

@MainActor
final class TerminalConnectionMarginsTests: XCTestCase {
    // A previous connection can leave DECLRMM enabled at its old width.
    // A new tmux client need not negotiate/use margins, so its full-screen
    // repaint assumes they are disabled and never sends the matching reset.
    private let staleMargins = "\u{1B}[?69h\u{1B}[1;40s\u{1B}[?6h\u{1B}[3;20r"

    func testRebindClearsMarginsForExistingAndFutureRenderers() {
        let original = MockPTYProcess()
        let controller = TerminalController(
            sessionID: UUID(), process: original, accessibilityIdentifier: "Margins",
            initialScrollback: Data(("history survives\r\n" + staleMargins).utf8)
        )
        _ = controller.terminalView(for: .grid)

        let replacement = MockPTYProcess()
        controller.rebind(process: replacement)

        _ = controller.terminalView(for: .peek)
        for presentation in [TerminalPresentation.session, .grid, .peek] {
            XCTAssertTrue(controller.bufferText(for: presentation).contains("history survives"))
            assertFullWidthPaint(controller, presentation: presentation)
        }
        XCTAssertTrue(original.sentInput.isEmpty)
        XCTAssertTrue(replacement.sentInput.isEmpty, "Display resets must never become agent input")
    }

    func testRestoredTmuxScrollbackCannotConstrainFreshClientRepaint() {
        let process = MockPTYProcess()
        let controller = TerminalController(
            sessionID: UUID(), process: process, accessibilityIdentifier: "RestoredMargins",
            initialScrollback: Data(("saved history\r\n" + staleMargins).utf8),
            customReflowHandler: { _ in }
        )
        XCTAssertTrue(controller.bufferText(for: .session).contains("saved history"))
        // A renderer created later must replay the connection boundary too.
        for presentation in [TerminalPresentation.session, .grid, .peek] {
            assertFullWidthPaint(controller, presentation: presentation)
        }
        XCTAssertTrue(process.sentInput.isEmpty)
    }

    private func assertFullWidthPaint(
        _ controller: TerminalController, presentation: TerminalPresentation,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let view = controller.terminalView(for: presentation)
        let terminal = view.getTerminal()
        // Exercise widening, narrowing and widening again, with a tmux-like
        // absolute cursor move and an ASCII run spanning the old margin.
        for width in [120, 90, 140] {
            terminal.resize(cols: width, rows: 30)
            view.feed(text: "\u{1B}[2J\u{1B}[1;1H" + String(repeating: "X", count: width - 1))
            XCTAssertEqual(terminal.getCharacter(col: width - 2, row: 0), "X", file: file, line: line)
        }
    }
}
