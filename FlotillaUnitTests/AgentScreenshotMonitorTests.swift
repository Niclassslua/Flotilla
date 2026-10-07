import AppKit
import XCTest
import CompanionKit
import SessionKit
import TranscriptKit
@testable import Flotilla

/// The monitor pops the inspector open on its own, so a wrong answer here is
/// either a missed screenshot or a panel that interrupts the user with an
/// image they pasted themselves.
final class AgentScreenshotMonitorTests: XCTestCase {
    private let pasteTime = Date(timeIntervalSince1970: 100)
    private let toolTime = Date(timeIntervalSince1970: 200)
    private let sendTime = Date(timeIntervalSince1970: 300)

    private var events: [TranscriptEvent] {
        [
            TranscriptEvent(id: "0", content: .userMessage(text: "What's wrong here?", timestamp: pasteTime)),
            TranscriptEvent(id: "1", content: .image(mimeType: "image/png", base64: "pasted", filename: nil, timestamp: pasteTime)),
            TranscriptEvent(id: "2", content: .toolUse(id: "t1", tool: "Read", input: [:], timestamp: toolTime)),
            TranscriptEvent(id: "3", content: .toolResult(toolUseID: "t1", output: "", isError: false, timestamp: toolTime)),
            TranscriptEvent(id: "4", content: .image(mimeType: "image/jpeg", base64: "read", filename: nil, timestamp: toolTime)),
            TranscriptEvent(id: "5", content: .toolUse(id: "t2", tool: "SendUserFile", input: [:], timestamp: sendTime)),
            TranscriptEvent(id: "6", content: .image(mimeType: "image/jpeg", base64: "sent", filename: nil, timestamp: sendTime)),
        ]
    }

    func testAgentImagesSkipsImagesThatArrivedWithAUserMessage() {
        let found = AgentScreenshotMonitor.agentImages(in: events)

        XCTAssertEqual(found.map(\.base64), ["read", "sent"])
        XCTAssertEqual(found.map(\.id), ["4", "6"])
    }

    func testAgentImagesOnlyReturnsImagesPastTheBaseline() {
        let found = AgentScreenshotMonitor.agentImages(in: events, after: .init(line: 4, entry: 0))

        XCTAssertEqual(found.map(\.base64), ["sent"])
    }

    func testAgentImagesUsesPositionWhenEventIDsAreCompound() {
        let compoundEvents = events.enumerated().map { offset, event in
            TranscriptEvent(id: offset == 1 ? "0:1" : "\(offset):0", content: event.content)
        }

        let found = AgentScreenshotMonitor.agentImages(in: compoundEvents, after: .init(line: 4, entry: 0))

        XCTAssertEqual(found.map(\.base64), ["sent"])
        XCTAssertEqual(found.map(\.id), ["6:0"])
    }

    func testAgentImagesKeepTheirPositionWhenOlderEventsAreTrimmed() {
        let firstWindow = events.enumerated().map { offset, event in
            TranscriptEvent(id: offset == 1 ? "0:1" : "\(offset):0", content: event.content)
        }
        let nextWindow = Array(firstWindow.dropFirst(3)) + [
            TranscriptEvent(id: "7:0", content: .image(mimeType: "image/png", base64: "new", filename: nil, timestamp: Date(timeIntervalSince1970: 400)))
        ]

        let baseline = AgentScreenshotMonitor.agentImages(in: firstWindow).last?.position
        let found = AgentScreenshotMonitor.agentImages(in: nextWindow, after: baseline)

        XCTAssertEqual(found.map(\.base64), ["new"])
        XCTAssertEqual(found.map(\.id), ["7:0"])
    }

    func testAgentImageIsNotHiddenByUserMessageInAnotherRecordAtSameTime() {
        let sameTime = Date(timeIntervalSince1970: 500)
        let events = [
            TranscriptEvent(id: "10:0", content: .userMessage(text: "hello", timestamp: sameTime)),
            TranscriptEvent(id: "11:0", content: .toolUse(id: "send", tool: "SendUserFile", input: [:], timestamp: sameTime)),
            TranscriptEvent(id: "11:1", content: .image(mimeType: "image/png", base64: "sent", filename: nil, timestamp: sameTime))
        ]

        XCTAssertEqual(AgentScreenshotMonitor.agentImages(in: events).map(\.base64), ["sent"])
    }

    func testAgentImagesSkipsImagesReadFromUserProvidedImagePath() {
        let userTime = Date(timeIntervalSince1970: 100)
        let toolTime = Date(timeIntervalSince1970: 200)
        let imagePath = "/Users/dev/Downloads/IMG_9556.PNG"
        let events = [
            TranscriptEvent(id: "5:0", content: .userMessage(text: "The live activity is at the top: \(imagePath)", timestamp: userTime)),
            TranscriptEvent(id: "23:0", content: .toolUse(id: "call_read", tool: "Read", input: ["file_path": imagePath], timestamp: toolTime)),
            TranscriptEvent(id: "24:0", content: .toolResult(toolUseID: "call_read", output: "", isError: false, timestamp: toolTime)),
            TranscriptEvent(id: "24:1", content: .image(mimeType: "image/png", base64: "user_attached_data", filename: nil, timestamp: toolTime))
        ]

        let found = AgentScreenshotMonitor.agentImages(in: events)
        XCTAssertTrue(found.isEmpty, "An image from a path attached in the user prompt must not be recognized as an agent screenshot")
    }

    func testAgentImagesSkipsImagesReadFromUserTildePath() {
        let userTime = Date(timeIntervalSince1970: 100)
        let toolTime = Date(timeIntervalSince1970: 200)
        let home = NSHomeDirectory()
        let absolutePath = "\(home)/Downloads/sample.png"
        let events = [
            TranscriptEvent(id: "1:0", content: .userMessage(text: "Check ~/Downloads/sample.png please", timestamp: userTime)),
            TranscriptEvent(id: "2:0", content: .toolUse(id: "call_read", tool: "Read", input: ["file_path": absolutePath], timestamp: toolTime)),
            TranscriptEvent(id: "3:0", content: .toolResult(toolUseID: "call_read", output: "", isError: false, timestamp: toolTime)),
            TranscriptEvent(id: "3:1", content: .image(mimeType: "image/png", base64: "data", filename: nil, timestamp: toolTime))
        ]

        let found = AgentScreenshotMonitor.agentImages(in: events)
        XCTAssertTrue(found.isEmpty, "An image from a tilde path attached in the user prompt must not be recognized as an agent screenshot")
    }

    func testAgentImagesSkipsImagesReadFromFilenameMentionedInUserMessage() {
        let userTime = Date(timeIntervalSince1970: 100)
        let toolTime = Date(timeIntervalSince1970: 200)
        let events = [
            TranscriptEvent(id: "1:0", content: .userMessage(text: "Please use Julius.png as the picture", timestamp: userTime)),
            TranscriptEvent(id: "2:0", content: .toolUse(id: "call_read", tool: "Read", input: ["file_path": "/var/app/Julius.png"], timestamp: toolTime)),
            TranscriptEvent(id: "3:0", content: .toolResult(toolUseID: "call_read", output: "", isError: false, timestamp: toolTime)),
            TranscriptEvent(id: "3:1", content: .image(mimeType: "image/png", base64: "data", filename: nil, timestamp: toolTime))
        ]

        let found = AgentScreenshotMonitor.agentImages(in: events)
        XCTAssertTrue(found.isEmpty, "An image whose filename was referenced in the user prompt must not be recognized as an agent screenshot")
    }

    func testAgentImagesRetainsScreenshotsCreatedByAgent() {
        let userTime = Date(timeIntervalSince1970: 100)
        let toolTime = Date(timeIntervalSince1970: 200)
        let events = [
            TranscriptEvent(id: "1:0", content: .userMessage(text: "take a screenshot of the app and review it", timestamp: userTime)),
            TranscriptEvent(id: "2:0", content: .toolUse(id: "call_read", tool: "Read", input: ["file_path": "/tmp/claude-scratch/screen.png"], timestamp: toolTime)),
            TranscriptEvent(id: "3:0", content: .toolResult(toolUseID: "call_read", output: "", isError: false, timestamp: toolTime)),
            TranscriptEvent(id: "3:1", content: .image(mimeType: "image/png", base64: "agent_screenshot_data", filename: nil, timestamp: toolTime))
        ]

        let found = AgentScreenshotMonitor.agentImages(in: events)
        XCTAssertEqual(found.map(\.base64), ["agent_screenshot_data"])
    }

    func testAgentImagesSkipsImagesReadFromProjectLogoPaths() {
        let userTime = Date(timeIntervalSince1970: 100)
        let toolTime = Date(timeIntervalSince1970: 200)
        let events = [
            TranscriptEvent(id: "1:0", content: .userMessage(text: "Review the header branding", timestamp: userTime)),
            TranscriptEvent(id: "2:0", content: .toolUse(id: "call_read", tool: "Read", input: ["file_path": "LaunchVideo/public/logos/codex.png"], timestamp: toolTime)),
            TranscriptEvent(id: "3:0", content: .toolResult(toolUseID: "call_read", output: "", isError: false, timestamp: toolTime)),
            TranscriptEvent(id: "3:1", content: .image(mimeType: "image/png", base64: "logo_data", filename: nil, timestamp: toolTime))
        ]

        let found = AgentScreenshotMonitor.agentImages(in: events)
        XCTAssertTrue(found.isEmpty, "Reading a project logo like LaunchVideo/public/logos/codex.png must not be treated as an agent screenshot")
    }

    func testAgentImagesSkipsImagesReadFromDocumentationPaths() {
        let userTime = Date(timeIntervalSince1970: 100)
        let toolTime = Date(timeIntervalSince1970: 200)
        let events = [
            TranscriptEvent(id: "1:0", content: .userMessage(text: "Search for references to the companion fleet", timestamp: userTime)),
            TranscriptEvent(id: "2:0", content: .toolUse(id: "call_read", tool: "Read", input: ["file_path": "docs/images/ui-vocabulary/companion-fleet.png"], timestamp: toolTime)),
            TranscriptEvent(id: "3:0", content: .toolResult(toolUseID: "call_read", output: "", isError: false, timestamp: toolTime)),
            TranscriptEvent(id: "3:1", content: .image(mimeType: "image/png", base64: "doc_image_data", filename: nil, timestamp: toolTime))
        ]

        let found = AgentScreenshotMonitor.agentImages(in: events)
        XCTAssertTrue(found.isEmpty, "Reading a documentation image must not be treated as an agent screenshot")
    }

    func testAgentImagesRetainsScreenshotsExplicitlyNamedInProjectDirectory() {
        let userTime = Date(timeIntervalSince1970: 100)
        let toolTime = Date(timeIntervalSince1970: 200)
        let events = [
            TranscriptEvent(id: "1:0", content: .userMessage(text: "Inspect the captured screenshot", timestamp: userTime)),
            TranscriptEvent(id: "2:0", content: .toolUse(id: "call_read", tool: "Read", input: ["file_path": "screenshots/app-preview.png"], timestamp: toolTime)),
            TranscriptEvent(id: "3:0", content: .toolResult(toolUseID: "call_read", output: "", isError: false, timestamp: toolTime)),
            TranscriptEvent(id: "3:1", content: .image(mimeType: "image/png", base64: "preview_data", filename: nil, timestamp: toolTime))
        ]

        let found = AgentScreenshotMonitor.agentImages(in: events)
        XCTAssertEqual(found.map(\.base64), ["preview_data"])
    }

    @MainActor
    func testMergingScreenshotsRetainsAnImageTrimmedFromTheTranscriptWindow() {
        let sessionID = UUID()
        let older = screenshot(id: "20:1", line: 20, sessionID: sessionID)
        let newer = screenshot(id: "450:1", line: 450, sessionID: sessionID)

        // This mirrors the 400-event transcript window after newer messages
        // have pushed the original Claude screenshot out of it.
        let merged = AgentScreenshotMonitor.merging([older], with: [newer])

        XCTAssertEqual(merged.map(\.id), ["20:1", "450:1"])
    }

    /// A screenshot sent early in a long Claude turn, followed by more
    /// records than the reader's event window holds.
    private func longClaudeTranscript() throws -> (session: Session, url: URL, imageURL: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("screenshots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imageURL = directory.appendingPathComponent("screenshot.png")
        try Data(base64Encoded: Self.pixelPNG)!.write(to: imageURL)
        let url = directory.appendingPathComponent("transcript.jsonl")
        let send: [String: Any] = [
            "type": "assistant", "timestamp": "2026-01-01T00:00:00Z",
            "message": ["role": "assistant", "content": [[
                "type": "tool_use", "id": "toolu_send", "name": "SendUserFile",
                "input": ["files": [imageURL.path]]
            ]]]
        ]
        var lines = [String(decoding: try JSONSerialization.data(withJSONObject: send), as: UTF8.self)]
        for index in 0..<(CompanionProtocol.transcriptEventLimit + 50) {
            lines.append(#"{"type":"assistant","timestamp":"2026-01-01T00:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"step \#(index)"}]}}"#)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        var session = Session(title: "Shots", goal: "Shots", agent: .claudeCode, projectID: nil,
                              workingDirectory: directory, status: .working)
        session.nativeTranscriptPath = url
        return (session, url, imageURL)
    }

    func testImageEventsFindAScreenshotThatFellOutOfTheTranscriptWindow() async throws {
        let (session, url, _) = try longClaudeTranscript()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let reader = CompanionTranscriptReader(registry: .default)

        let window = await reader.read(session).events
        XCTAssertTrue(AgentScreenshotMonitor.agentImages(in: window).isEmpty)

        let history = await reader.imageEvents(session)
        XCTAssertEqual(AgentScreenshotMonitor.agentImages(in: history).map(\.id), ["0:1"])
    }

    @MainActor
    func testScreenshotSurvivesFocusingAnotherSessionAndComingBack() async throws {
        let (session, url, imageURL) = try longClaudeTranscript()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let monitor = AgentScreenshotMonitor(
            reader: CompanionTranscriptReader(registry: .default),
            store: AgentScreenshotStore(supportDirectory: url.deletingLastPathComponent())
        )

        monitor.focus(session)
        try await waitUntil { !monitor.screenshots.isEmpty }
        XCTAssertEqual(monitor.screenshots.map(\.id), ["0:1"])

        // Agents clean up their scratchpads; the sent image must outlive it.
        try FileManager.default.removeItem(at: imageURL)
        monitor.focus(nil)
        monitor.focus(session)
        XCTAssertEqual(monitor.screenshots.map(\.id), ["0:1"])
    }

    @MainActor
    func testStoredScreenshotSurvivesARelaunchAfterItsFileIsGone() async throws {
        let (session, url, imageURL) = try longClaudeTranscript()
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentScreenshotStore(supportDirectory: directory)

        let first = AgentScreenshotMonitor(reader: CompanionTranscriptReader(registry: .default), store: store)
        first.focus(session)
        try await waitUntil { !first.screenshots.isEmpty }
        var stored: [AgentScreenshotStore.Stored] = []
        while stored.isEmpty {
            stored = await store.load(session.id)
            try await Task.sleep(for: .milliseconds(20))
        }

        try FileManager.default.removeItem(at: imageURL)
        let relaunched = AgentScreenshotMonitor(reader: CompanionTranscriptReader(registry: .default), store: store)
        relaunched.focus(session)
        try await waitUntil { !relaunched.screenshots.isEmpty }
        XCTAssertEqual(relaunched.screenshots.map(\.id), ["0:1"])
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(5)
        while !condition() {
            guard Date.now < deadline else { return XCTFail("condition never became true") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static let pixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

    @MainActor
    private func screenshot(id: String, line: Int, sessionID: UUID) -> AgentScreenshot {
        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
        return AgentScreenshot(
            id: id,
            position: .init(line: line, entry: 1),
            sessionID: sessionID,
            agent: .claudeCode,
            image: NSImage(data: data)!,
            data: data,
            filename: nil,
            timestamp: .now
        )
    }
}
