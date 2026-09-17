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
}
