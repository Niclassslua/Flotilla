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
            TranscriptEvent(id: "1", content: .image(mimeType: "image/png", base64: "pasted", timestamp: pasteTime)),
            TranscriptEvent(id: "2", content: .toolUse(id: "t1", tool: "Read", input: [:], timestamp: toolTime)),
            TranscriptEvent(id: "3", content: .toolResult(toolUseID: "t1", output: "", isError: false, timestamp: toolTime)),
            TranscriptEvent(id: "4", content: .image(mimeType: "image/jpeg", base64: "read", timestamp: toolTime)),
            TranscriptEvent(id: "5", content: .toolUse(id: "t2", tool: "SendUserFile", input: [:], timestamp: sendTime)),
            TranscriptEvent(id: "6", content: .image(mimeType: "image/jpeg", base64: "sent", timestamp: sendTime)),
        ]
    }

    func testAgentImagesSkipsImagesThatArrivedWithAUserMessage() {
        let found = AgentScreenshotMonitor.agentImages(in: events, after: -1)

        XCTAssertEqual(found.map(\.base64), ["read", "sent"])
        XCTAssertEqual(found.map(\.index), [4, 6])
    }

    func testAgentImagesOnlyReturnsImagesPastTheBaseline() {
        let found = AgentScreenshotMonitor.agentImages(in: events, after: 4)

        XCTAssertEqual(found.map(\.base64), ["sent"])
    }
}
