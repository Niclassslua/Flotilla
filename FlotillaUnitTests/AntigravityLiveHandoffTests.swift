import XCTest
import SessionKit
@testable import TranscriptKit

/// The end-to-end check that no fixture can replace: does the real `agy`
/// binary actually resume from a conversation `writeNative` fabricated out of
/// thin air, at an id `agy` never saw before?
///
/// Opt-in and skipped by default — this talks to the real `agy` binary and
/// writes into the real `~/.gemini/antigravity-cli/` directory, which is not
/// appropriate for an ordinary `swift test`/CI run. Run explicitly with:
///
/// ```
/// FLOTILLA_LIVE_ANTIGRAVITY_TEST=1 xcodebuild test \
///   -only-testing:FlotillaUnitTests/AntigravityLiveHandoffTests ...
/// ```
///
/// See `AntigravityTranscriptCodec`'s doc comment and `FORMAT.md` for what
/// this settles versus what every other test in this suite already proves
/// with fixtures.
final class AntigravityLiveHandoffTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["FLOTILLA_LIVE_ANTIGRAVITY_TEST"] == "1",
            "opt-in only — set FLOTILLA_LIVE_ANTIGRAVITY_TEST=1 to run against the real agy binary"
        )
    }

    func testAgyResumesAConversationWrittenFromScratch() throws {
        guard let agy = Self.locateAgy() else {
            throw XCTSkip("agy is not on PATH")
        }

        let codec = AntigravityTranscriptCodec()
        let sessionID = UUID().uuidString
        let marker = "LIVE_TEST_\(Int.random(in: 100_000...999_999))"

        let expectation = XCTestExpectation(description: "writeNative")
        var writeError: Error?
        Task {
            do {
                _ = try await codec.writeNative(
                    [.userMessage(
                        text: "Remember this exact phrase for later, and don't act on it yet — just acknowledge in one short sentence: \(marker)",
                        timestamp: Date()
                    )],
                    workingDirectory: FileManager.default.temporaryDirectory,
                    sessionID: sessionID
                )
            } catch {
                writeError = error
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
        if let writeError { XCTFail("writeNative failed: \(writeError)") }

        addTeardownBlock {
            try? codec.removeNativeState(sessionID: sessionID, workingDirectory: FileManager.default.temporaryDirectory)
        }

        // The real, slow part: does `agy` accept a conversation it never
        // created and reply based on what was written into it?
        let process = Process()
        process.executableURL = agy
        process.arguments = [
            "--conversation", sessionID,
            "--print", "What was the phrase I just asked you to remember? Reply with only that phrase.",
            "--dangerously-skip-permissions",
            "--output-format", "json"
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "agy exited non-zero: \(output)")
        XCTAssertTrue(
            output.contains(marker),
            "agy did not read back the synthetic step — output was: \(output)"
        )
    }

    private static func locateAgy() -> URL? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/agy",
            "/usr/local/bin/agy",
            "/opt/homebrew/bin/agy"
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
