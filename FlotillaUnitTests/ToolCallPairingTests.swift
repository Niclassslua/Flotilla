import XCTest
import SessionKit
@testable import TranscriptKit

/// The pairing invariant is what stops a handed-off conversation from being
/// rejected by the receiving provider on its very first turn, so these cases
/// are about the shapes a real interrupted session actually produces.
final class ToolCallPairingTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func toolUse(_ id: String) -> CanonicalEntry {
        .toolUse(id: id, tool: "Bash", input: Data("{}".utf8), timestamp: epoch)
    }

    private func toolResult(_ id: String, output: String = "ok") -> CanonicalEntry {
        .toolResult(toolUseID: id, output: output, isError: false, timestamp: epoch)
    }

    func testAlreadyPairedInputIsUnchanged() {
        let entries: [CanonicalEntry] = [
            .userMessage(text: "run it", timestamp: epoch),
            .assistantMessage(text: "sure", timestamp: epoch),
            toolUse("a"),
            toolResult("a")
        ]

        let outcome = ToolCallPairing.pair(entries)

        XCTAssertEqual(outcome.entries, entries)
        XCTAssertEqual(outcome.synthesizedResults, 0)
        XCTAssertEqual(outcome.droppedOrphanResults, 0)
    }

    /// The characteristic handoff case: the user moved agents while a tool was
    /// still running, so the call has no answer.
    func testDanglingToolCallGetsSynthesizedErrorResult() throws {
        let entries: [CanonicalEntry] = [
            .userMessage(text: "run it", timestamp: epoch),
            .assistantMessage(text: "working", timestamp: epoch),
            toolUse("a")
        ]

        let outcome = ToolCallPairing.pair(entries)

        XCTAssertEqual(outcome.synthesizedResults, 1)
        XCTAssertEqual(outcome.entries.count, 4)
        let last = try XCTUnwrap(outcome.entries.last)
        guard case let .toolResult(toolUseID, output, isError, _) = last else {
            return XCTFail("expected a synthesized tool result, got \(last)")
        }
        XCTAssertEqual(toolUseID, "a")
        XCTAssertTrue(isError)
        XCTAssertEqual(output, ToolCallPairing.missingResultText)
    }

    func testOrphanResultWithNoCallIsDropped() {
        let entries: [CanonicalEntry] = [
            .userMessage(text: "hi", timestamp: epoch),
            toolResult("ghost")
        ]

        let outcome = ToolCallPairing.pair(entries)

        XCTAssertEqual(outcome.droppedOrphanResults, 1)
        XCTAssertEqual(outcome.entries, [.userMessage(text: "hi", timestamp: epoch)])
    }

    /// A turn that fires several tools at once must come back with each call
    /// answered, in call order, behind the whole assistant run.
    func testParallelToolCallsAreEachAnsweredInCallOrder() {
        let entries: [CanonicalEntry] = [
            .assistantMessage(text: "checking three things", timestamp: epoch),
            toolUse("a"),
            toolUse("b"),
            toolUse("c"),
            toolResult("b", output: "second"),
            toolResult("a", output: "first")
        ]

        let outcome = ToolCallPairing.pair(entries)

        XCTAssertEqual(outcome.synthesizedResults, 1, "c never returned")
        XCTAssertEqual(outcome.droppedOrphanResults, 0)

        let resultIDs: [String] = outcome.entries.compactMap { entry in
            guard case let .toolResult(id, _, _, _) = entry else { return nil }
            return id
        }
        XCTAssertEqual(resultIDs, ["a", "b", "c"])

        // The assistant text and all three calls precede every result.
        let firstResultIndex = outcome.entries.firstIndex { entry in
            if case .toolResult = entry { return true }
            return false
        }
        XCTAssertEqual(firstResultIndex, 4)
    }

    func testEmptyInputIsEmptyOutput() {
        let outcome = ToolCallPairing.pair([])
        XCTAssertTrue(outcome.entries.isEmpty)
        XCTAssertEqual(outcome.synthesizedResults, 0)
        XCTAssertEqual(outcome.droppedOrphanResults, 0)
    }

    func testNonToolEntriesPassThroughUntouched() {
        let entries: [CanonicalEntry] = [
            .userMessage(text: "one", timestamp: epoch),
            .systemNote(text: "note", timestamp: epoch),
            .handoffMarker(from: .claudeCode, to: .codexCLI, reason: "user-requested", timestamp: epoch)
        ]

        XCTAssertEqual(ToolCallPairing.pair(entries).entries, entries)
    }
}
