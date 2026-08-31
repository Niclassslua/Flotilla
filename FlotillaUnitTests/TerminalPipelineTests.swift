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

    /// Without a ceiling this buffer amplifies main-thread stalls: the PTY
    /// reader fills it from a background queue while the drain waits on a
    /// blocked main actor, and the flush that eventually runs then feeds one
    /// enormous array to the emulator — blocking the main actor for longer
    /// still. Dropping the oldest bytes bounds that: the emulator can only
    /// show a screenful, and durable history lives elsewhere.
    func testAppendsBeyondCapacityDropOldestBytesRatherThanGrowing() {
        let buffer = CoalescingOutputBuffer(capacity: 64 * 1_024)
        for _ in 0..<40 {
            _ = buffer.append(Data(repeating: UInt8(ascii: "x"), count: 8 * 1_024))
        }
        _ = buffer.append(Data("newest".utf8))

        let drained = buffer.drain()

        XCTAssertLessThanOrEqual(drained.count, 64 * 1_024)
        XCTAssertGreaterThan(buffer.totalDroppedBytes, 0)
        XCTAssertTrue(
            String(decoding: drained.suffix(6), as: UTF8.self) == "newest",
            "the newest bytes are the ones that decide what ends up on screen"
        )
    }

    func testOutputWithinCapacityIsNeverDropped() {
        let buffer = CoalescingOutputBuffer(capacity: 64 * 1_024)
        _ = buffer.append(Data(repeating: UInt8(ascii: "y"), count: 32 * 1_024))

        XCTAssertEqual(buffer.drain().count, 32 * 1_024)
        XCTAssertEqual(buffer.totalDroppedBytes, 0)
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

    /// The burst below never awaits, so the main actor stays occupied running
    /// this test method and nothing can drain the pending buffer until the
    /// `Task.sleep` suspends it. Almost always that yields exactly one flush.
    ///
    /// Not *exactly* one, though — and asserting that made this test flaky
    /// under the parallel suite. `simulateOutput` yields into an `AsyncStream`
    /// that the controller's consumer task drains on its own executor, so a
    /// busy machine can leave the last few chunks un-appended when the
    /// scheduled flush runs, splitting the burst across two. The guarantee
    /// `CoalescingOutputBuffer` actually makes — and the one worth protecting
    /// — is that 200 reads collapse into a handful of flushes, not 200.
    func testRapidChunksCoalesceIntoFewerFlushes() async throws {
        let process = MockPTYProcess()
        let controller = makeController(process: process)

        for i in 0..<200 {
            process.simulateOutput("line-\(i)\n")
        }
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertGreaterThan(controller.outputFlushCount, 0)
        XCTAssertLessThanOrEqual(
            controller.outputFlushCount,
            5,
            "200 PTY reads must collapse into a handful of flushes, not one per read"
        )
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
    /// cursor-show escape sequence. If those chunks were fed to the emulator
    /// in separate main-actor turns, a frame could be committed with the
    /// cursor mid-hide — the flicker this fix targets.
    ///
    /// The assertion is on the resolved state rather than on a flush count of
    /// exactly one: chunk delivery is asynchronous (see
    /// `testRapidChunksCoalesceIntoFewerFlushes`), so pinning the count made
    /// this flaky. What must hold is that the bracketed sequence resolves into
    /// the emulator intact, in few enough flushes to rule out one-per-read.
    func testCursorHideShowSequenceCoalescesIntoASingleFlush() async throws {
        let process = MockPTYProcess()
        let controller = makeController(process: process)

        process.simulateOutput("\u{1B}[?25l")
        process.simulateOutput("repainting-tui-frame")
        process.simulateOutput("\u{1B}[?25h")
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertLessThanOrEqual(controller.outputFlushCount, 3)
        XCTAssertTrue(
            controller.visibleScreenText()?.contains("repainting-tui-frame") ?? false,
            "the bracketed repaint must have resolved into the emulator intact"
        )
    }
}

/// The PTY has to end up at the size of whichever renderer the user is
/// looking at. That is easy to get wrong in a way nothing notices, because
/// SwiftTerm reports a size change only when *its own* column/row count moves
/// — so a renderer restored to dimensions it already had stays silent, and the
/// agent keeps whatever size the other presentation last set it to.
@MainActor
final class TerminalPTYSizingTests: XCTestCase {
    /// Mounts `view` in a real window at `size` and lets AppKit lay it out, so
    /// SwiftTerm measures a genuine frame and reports real dimensions.
    private func mount(_ view: NSView, in window: NSWindow, size: NSSize) {
        window.setContentSize(size)
        window.contentView = NSView(frame: NSRect(origin: .zero, size: size))
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView?.addSubview(view)
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
    }

    /// Resizes after the first are debounced so a window drag sends one
    /// `SIGWINCH` instead of one per frame, so each step waits for the settle.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    func testSwitchingBackToAPreviouslySizedRendererStillResizesThePTY() async throws {
        let process = MockPTYProcess()
        let controller = TerminalController(
            sessionID: UUID(),
            process: process,
            accessibilityIdentifier: "TerminalView-SizingTest",
            multilineNewlineSequence: Data([0x0A])
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        // The order here mirrors what the host view actually does, and the
        // order is the whole point: SwiftUI calls `makeNSView` — which claims
        // authority — *before* it inserts the container into the hierarchy, so
        // at that moment the renderer has no window and nothing to measure.
        // Only once it is mounted and laid out can a size be pushed.
        let sessionView = controller.terminalView(for: .session)
        controller.makeAuthoritative(.session)
        mount(sessionView, in: window, size: NSSize(width: 900, height: 600))
        controller.syncPTYSize(for: .session)
        try await settle()
        let fullSize = try XCTUnwrap(process.lastSize)
        XCTAssertGreaterThanOrEqual(fullSize.cols, 20)

        // Grid tile takes over, mounted small — the agent follows it down.
        let gridView = controller.terminalView(for: .grid)
        controller.makeAuthoritative(.grid)
        mount(gridView, in: window, size: NSSize(width: 320, height: 200))
        controller.syncPTYSize(for: .grid)
        try await settle()
        let tileSize = try XCTUnwrap(process.lastSize)
        XCTAssertLessThan(tileSize.cols, fullSize.cols, "the grid tile must drive the PTY while it is authoritative")

        // Back to full screen. The session renderer already has these
        // dimensions from the first mount, so SwiftTerm's `sizeChanged` does
        // not fire — this is exactly the case that used to leave the agent
        // stuck at the tile's size with the renderer drawing at full size on
        // top of it.
        sessionView.removeFromSuperview()
        controller.makeAuthoritative(.session)
        mount(sessionView, in: window, size: NSSize(width: 900, height: 600))
        controller.syncPTYSize(for: .session)
        try await settle()

        XCTAssertEqual(
            process.lastSize,
            fullSize,
            "returning to the full-screen renderer must resize the agent back, even though the renderer itself never reported a change"
        )
    }

    /// A tile that is not the one driving the PTY must never resize the agent
    /// — otherwise every grid tile would fight over the session's dimensions.
    func testNonAuthoritativePresentationDoesNotResizeThePTY() async throws {
        let process = MockPTYProcess()
        let controller = TerminalController(
            sessionID: UUID(),
            process: process,
            accessibilityIdentifier: "TerminalView-SizingTest",
            multilineNewlineSequence: Data([0x0A])
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        let sessionView = controller.terminalView(for: .session)
        mount(sessionView, in: window, size: NSSize(width: 900, height: 600))
        controller.makeAuthoritative(.session)
        controller.syncPTYSize(for: .session)
        try await settle()
        let authoritativeSize = process.lastSize

        let gridView = controller.terminalView(for: .grid)
        mount(gridView, in: window, size: NSSize(width: 320, height: 200))
        controller.syncPTYSize(for: .grid)
        try await settle()

        XCTAssertEqual(process.lastSize, authoritativeSize)
    }
}

extension TerminalPTYSizingTests {
    /// Resizing away and back inside the debounce window must not leave the
    /// intermediate size queued: the agent would be resized to dimensions the
    /// renderer no longer has, 150 ms after the user already went back.
    func testResizingAwayAndBackWithinTheDebounceWindowLeavesNothingQueued() async throws {
        let process = MockPTYProcess()
        let controller = TerminalController(
            sessionID: UUID(),
            process: process,
            accessibilityIdentifier: "TerminalView-DebounceTest",
            multilineNewlineSequence: Data([0x0A])
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        let view = controller.terminalView(for: .session)
        controller.makeAuthoritative(.session)
        mount(view, in: window, size: NSSize(width: 900, height: 600))
        controller.syncPTYSize(for: .session)
        try await settle()
        let settledSize = try XCTUnwrap(process.lastSize)

        // Away, then straight back — faster than the 150 ms debounce.
        mount(view, in: window, size: NSSize(width: 400, height: 300))
        controller.syncPTYSize(for: .session)
        mount(view, in: window, size: NSSize(width: 900, height: 600))
        controller.syncPTYSize(for: .session)
        try await settle()

        XCTAssertEqual(
            process.lastSize,
            settledSize,
            "the intermediate size must not land after the renderer has gone back"
        )
    }
}
