import XCTest
import SessionKit
import TranscriptKit
@testable import CompanionKit

final class PairingPayloadTests: XCTestCase {
    private func payload() -> PairingPayload {
        PairingPayload(
            macID: "mac-1",
            macName: "Studio",
            macKey: CompanionIdentity().publicKey,
            secret: Handshake.randomSecret(),
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            candidates: [
                HostCandidate(kind: .lan, host: "192.168.1.20", port: 48620),
                HostCandidate(kind: .tailscale, host: "100.101.5.3", port: 48620),
            ]
        )
    }

    func testLinkRoundTrips() throws {
        let original = payload()
        let parsed = try PairingPayload(link: original.link())
        XCTAssertEqual(parsed, original)
        XCTAssertTrue(parsed.hasLANCandidate)
        XCTAssertTrue(parsed.hasTailscaleCandidate)
    }

    func testPastedLinkWithWhitespaceStillParses() throws {
        let link = try payload().link()
        XCTAssertNoThrow(try PairingPayload(link: "  \n\(link)\n "))
    }

    func testOtherURLsAreNotPairingLinks() {
        XCTAssertThrowsError(try PairingPayload(link: "https://example.com/pair?p=abc")) { error in
            XCTAssertEqual(error as? PairingPayload.LinkError, .notAPairingLink)
        }
    }

    func testTruncatedLinkIsMalformed() throws {
        let link = try payload().link()
        XCTAssertThrowsError(try PairingPayload(link: String(link.dropLast(40)))) { error in
            XCTAssertEqual(error as? PairingPayload.LinkError, .malformed)
        }
    }

    func testNewerProtocolVersionIsReported() throws {
        var future = payload()
        future.version = 7
        XCTAssertThrowsError(try PairingPayload(link: future.link())) { error in
            XCTAssertEqual(error as? PairingPayload.LinkError, .unsupportedVersion(7))
        }
    }

    func testExpiry() {
        let value = payload()
        XCTAssertFalse(value.isExpired(at: Date(timeIntervalSince1970: 1_999_999_999)))
        XCTAssertTrue(value.isExpired(at: Date(timeIntervalSince1970: 2_000_000_000)))
    }
}

final class MessageCodingTests: XCTestCase {
    func testFleetSnapshotWithPendingInteractionsRoundTrips() throws {
        let sessionID = UUID()
        let snapshot = FleetSnapshot(
            macID: "mac-1",
            macName: "Studio",
            sessions: [CompanionSession(
                id: sessionID, title: "Fix tests", agent: .claudeCode, model: "opus", effort: .high,
                status: .waitingForInput, waitingReason: .question, hasWorktree: true, isProcessLive: true,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000), handoffTargets: [.codexCLI]
            )],
            projects: [ProjectSummary(id: UUID(), name: "Flotilla")],
            catalog: .fallback,
            pending: [sessionID: [PendingInteraction(
                kind: .question([QuestionStep(id: "q", header: "Storage", prompt: "Where?", options: [.init(label: "Keychain")], allowsMultiple: true)]),
                subagent: "general",
                raisedAt: Date(timeIntervalSince1970: 1_700_000_001)
            )]]
        )
        let message = ServerMessage.fleet(snapshot)
        let decoded = try CompanionJSON.decode(ServerMessage.self, from: CompanionJSON.encode(message))
        XCTAssertEqual(decoded, message)
    }

    func testEveryRequestShapeRoundTrips() throws {
        let id = UUID()
        let requests: [CompanionRequest] = [
            .sendPrompt(sessionID: id, text: "Go"),
            .stop(sessionID: id),
            .answer(sessionID: id, interactionID: UUID(), answer: .questionAnswers([QuestionAnswer(stepID: "q", selected: ["A", "B"], other: "C")])),
            .answer(sessionID: id, interactionID: UUID(), answer: .approvePlan(.autoAccept)),
            .answer(sessionID: id, interactionID: UUID(), answer: .denyWithNote("no")),
            .createSession(NewSessionRequest(goal: "g", projectID: nil, agent: .openCode, model: "m", effort: nil, createWorktree: false, fetchFirst: false, openCodeSubscription: .go)),
            .handoff(sessionID: id, HandoffRequest(agent: .codexCLI, model: "gpt", effort: .low, note: "")),
            .restart(sessionID: id),
            .delete(sessionID: id, removeWorktree: true),
            .diff(sessionID: id, commitHash: nil),
            .commits(sessionID: id),
            .file(sessionID: id, path: "README.md"),
        ]
        for request in requests {
            let message = ClientMessage.request(id: 42, request)
            XCTAssertEqual(try CompanionJSON.decode(ClientMessage.self, from: CompanionJSON.encode(message)), message)
        }
    }
}

final class TranscriptMappingTests: XCTestCase {
    func testToolArgumentsKeepScalarsFromAnObject() {
        let data = Data(#"{"command":"npm test","timeout":120,"nested":{"a":1}}"#.utf8)
        XCTAssertEqual(TranscriptEvent.Content.scalarArguments(data), ["command": "npm test", "timeout": "120"])
    }

    func testCodexStyleStringEncodedArgumentsAreDecoded() {
        let data = Data(#""{\"cmd\":\"ls -la\"}""#.utf8)
        XCTAssertEqual(TranscriptEvent.Content.scalarArguments(data), ["cmd": "ls -la"])
    }

    func testImagesAreDroppedAndHandoffsKept() {
        let now = Date()
        XCTAssertNil(TranscriptEvent.Content(.image(mimeType: "image/png", base64: "", timestamp: now)))
        XCTAssertEqual(
            TranscriptEvent.Content(.handoffMarker(from: .claudeCode, to: .codexCLI, reason: "r", timestamp: now)),
            .handoff(from: .claudeCode, to: .codexCLI, timestamp: now)
        )
    }

    func testLatestCompleteLineIgnoresTheStreamingPartial() {
        var transcript = SessionTranscript()
        transcript.append(.assistantMessage(text: "First\nSecond line", timestamp: .now))
        transcript.streamingText = "Streaming partial"
        XCTAssertEqual(transcript.latestCompleteLine, "Second line")
        transcript.streamingText = "Done line\nhalf"
        XCTAssertEqual(transcript.latestCompleteLine, "Done line")
    }
}

final class NetworkInterfaceTests: XCTestCase {
    func testClassification() {
        XCTAssertEqual(NetworkInterfaces.classify(address: "192.168.1.20", interface: "en0", isIPv6: false)?.path, .lan)
        XCTAssertEqual(NetworkInterfaces.classify(address: "10.0.0.5", interface: "en0", isIPv6: false)?.path, .lan)
        XCTAssertEqual(NetworkInterfaces.classify(address: "100.101.5.3", interface: "utun4", isIPv6: false)?.path, .tailscale)
        XCTAssertEqual(NetworkInterfaces.classify(address: "100.63.0.1", interface: "en0", isIPv6: false)?.path, .lan)
        XCTAssertEqual(NetworkInterfaces.classify(address: "fd7a:115c:a1e0::1234", interface: "utun4", isIPv6: true)?.path, .tailscale)
        XCTAssertNil(NetworkInterfaces.classify(address: "fe80::1%en0", interface: "en0", isIPv6: true))
        XCTAssertNil(NetworkInterfaces.classify(address: "169.254.3.3", interface: "en0", isIPv6: false))
    }
}
