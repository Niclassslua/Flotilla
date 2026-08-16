import XCTest
import ProcessKit
import TerminalKit

/// `CoalescingOutputBuffer` is the piece that turns "one main-actor hop per
/// PTY read" into "one flush per consumer turn" — the root fix for the
/// terminal's cursor flicker and dropped frame rate. These tests exercise it
/// in isolation, with no actor hops or timing involved.
final class CoalescingOutputBufferTests: XCTestCase {
    func testFirstAppendSchedulesAndSubsequentOnesDoNot() {
        let buffer = CoalescingOutputBuffer()
        XCTAssertTrue(buffer.append(Data("a".utf8)))
        XCTAssertFalse(buffer.append(Data("b".utf8)))
        XCTAssertFalse(buffer.append(Data("c".utf8)))
    }

    func testDrainReturnsChunksConcatenatedInOrder() {
        let buffer = CoalescingOutputBuffer()
        _ = buffer.append(Data("first-".utf8))
        _ = buffer.append(Data("second-".utf8))
        _ = buffer.append(Data("third".utf8))

        let drained = buffer.drain()

        XCTAssertEqual(String(decoding: drained, as: UTF8.self), "first-second-third")
    }

    func testDrainReArmsScheduling() {
        let buffer = CoalescingOutputBuffer()
        _ = buffer.append(Data("a".utf8))
        _ = buffer.drain()

        XCTAssertTrue(buffer.append(Data("b".utf8)))
    }

    func testDrainOnEmptyBufferReturnsEmpty() {
        let buffer = CoalescingOutputBuffer()
        XCTAssertEqual(buffer.drain(), Data())
    }
}

/// `TerminalController.consumeOutput` used to hop onto the main actor once
/// per PTY read (`await MainActor.run { ... view.feed(...) ... }`), so a
/// chatty TUI's repaint — which arrives as many small reads — was fed to the
/// emulator and re-rendered to SwiftUI many times per actual frame. It now
/// buffers everything that arrives before the scheduled flush runs and
/// applies it once. These tests drive that path end-to-end through a real
/// `TerminalController` and `MockPTYProcess`.
@MainActor
final class TerminalControllerCoalescingTests: XCTestCase {
    private func makeController(process: MockPTYProcess) -> TerminalController {
        TerminalController(
            sessionID: UUID(),
            process: process,
            accessibilityIdentifier: "TerminalView-CoalescingTest",
            multilineNewlineSequence: Data([0x0A])
        )
    }

    /// The synchronous burst below never awaits, so the main actor stays
    /// occupied running this test method — nothing can drain the pending
    /// buffer until the `Task.sleep` below suspends this test and lets the
    /// scheduled flush run. That makes exactly one flush deterministic here,
    /// not just likely: `flushPendingOutput` (and therefore `drain()`) can
    /// only run once the main actor is free, and by then every chunk in the
    /// burst has already been appended to the one pending buffer.
    func testRapidChunksCoalesceIntoFewerFlushes() async throws {
        let process = MockPTYProcess()
        let controller = makeController(process: process)

        for i in 0..<200 {
            process.simulateOutput("line-\(i)\n")
        }
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(controller.outputFlushCount, 1)
    }

    /// Short enough to stay on one row of the emulator's default screen
    /// width — with `scrollback: 0` (Flotilla's setting; see `TerminalController.makeTerminalView`),
    /// content that wraps or scrolls off is legitimately gone, so this checks
    /// coalescing doesn't drop or reorder bytes, not that history is retained.
    func testCoalescedOutputPreservesEveryByteInOrder() async throws {
        let process = MockPTYProcess()
        let controller = makeController(process: process)
        let markers = (0..<5).map { "m\($0)-" }

        for marker in markers {
            process.simulateOutput(marker)
        }
        try await Task.sleep(for: .milliseconds(200))

        let screen = controller.visibleScreenText() ?? ""
        XCTAssertTrue(screen.contains(markers.joined()), "expected contiguous, in-order: \(screen)")
    }

    /// A TUI repaint is typically bracketed by a cursor-hide and a matching
    /// cursor-show escape sequence. If those two chunks were fed to the
    /// emulator in separate main-actor turns, a frame could be committed
    /// with the cursor mid-hide — the flicker this fix targets. Coalescing
    /// means the whole bracketed sequence always resolves within one flush.
    func testCursorHideShowSequenceCoalescesIntoASingleFlush() async throws {
        let process = MockPTYProcess()
        let controller = makeController(process: process)

        process.simulateOutput("\u{1B}[?25l")
        process.simulateOutput("repainting-tui-frame")
        process.simulateOutput("\u{1B}[?25h")
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(controller.outputFlushCount, 1)
        XCTAssertTrue(controller.visibleScreenText()?.contains("repainting-tui-frame") ?? false)
    }
}
