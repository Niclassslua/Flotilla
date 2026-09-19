import AppKit
import XCTest
import CompanionKit
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
