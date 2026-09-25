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

    func testLinkParseEdgesAndExpiry() throws {
        let value = payload()
        let link = try value.link()

        XCTAssertNoThrow(try PairingPayload(link: "  \n\(link)\n "), "whitespace around a valid link still parses")

        struct ErrorCase {
            let name: String
            let link: () throws -> String
            let expected: PairingPayload.LinkError
        }
        let errorCases: [ErrorCase] = [
            ErrorCase(name: "other URL", link: { "https://example.com/pair?p=abc" }, expected: .notAPairingLink),
            ErrorCase(name: "truncated", link: { String(link.dropLast(40)) }, expected: .malformed),
            ErrorCase(name: "unsupported version", link: {
                var future = value
                future.version = 7
                return try future.link()
            }, expected: .unsupportedVersion(7)),
        ]
        for entry in errorCases {
            XCTAssertThrowsError(try PairingPayload(link: entry.link()), entry.name) { error in
                XCTAssertEqual(error as? PairingPayload.LinkError, entry.expected, entry.name)
            }
        }

        XCTAssertFalse(value.isExpired(at: Date(timeIntervalSince1970: 1_999_999_999)))
        XCTAssertTrue(value.isExpired(at: Date(timeIntervalSince1970: 2_000_000_000)))
    }
}

final class MessageCodingTests: XCTestCase {
    func testFleetDeltaReordersUpdatesAndRemovesSessionsWithoutLosingOtherRows() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let first = CompanionSession(id: UUID(), title: "First", agent: .codexCLI, model: "gpt", hasWorktree: false, isProcessLive: true, updatedAt: timestamp)
        let removed = CompanionSession(id: UUID(), title: "Gone", agent: .claudeCode, model: "opus", hasWorktree: false, isProcessLive: true, updatedAt: timestamp)
        let kept = CompanionSession(id: UUID(), title: "Unchanged", agent: .openCode, model: "model", hasWorktree: false, isProcessLive: true, updatedAt: timestamp)
        let old = FleetSnapshot(macID: "m", macName: "Studio", sessions: [first, removed, kept], projects: [], catalog: .fallback,
                                pending: [removed.id: [PendingInteraction(kind: .needsTerminal(dialogTitle: "Wait"))]])
        var changed = first
        changed.title = "Updated"
        let current = FleetSnapshot(macID: "m", macName: "Studio", sessions: [kept, changed], projects: [], catalog: .fallback)
        let delta = FleetDelta.make(from: old, to: current, baseRevision: 3)
        XCTAssertEqual(delta.changed.map(\.id), [first.id])
        XCTAssertEqual(delta.applying(to: old, revision: 3), current)
        XCTAssertNil(delta.applying(to: old, revision: 2))
    }

    func testFleetDeltaCarriesAccentChangesOnly() throws {
        let old = FleetSnapshot(macID: "m", macName: "Studio", sessions: [], projects: [], catalog: .fallback, accentColor: "orange")
        var recolored = old
        recolored.accentColor = "#3366FF"
        let delta = FleetDelta.make(from: old, to: recolored, baseRevision: 0)
        XCTAssertEqual(delta.accentColor, "#3366FF")
        XCTAssertEqual(delta.applying(to: old, revision: 0), recolored)
        XCTAssertNil(FleetDelta.make(from: old, to: old, baseRevision: 0).accentColor)
    }

    func testFleetSnapshotFromMacWithoutAccentDecodes() throws {
        let snapshot = FleetSnapshot(macID: "m", macName: "Studio", sessions: [], projects: [], catalog: .fallback)
        let decoded = try CompanionJSON.decode(FleetSnapshot.self, from: CompanionJSON.encode(snapshot))
        XCTAssertNil(decoded.accentColor)
    }

    func testEveryRequestShapeRoundTrips() throws {
        let id = UUID()
        let requests: [CompanionRequest] = [
            .sendPrompt(sessionID: id, text: "Go"),
            .stop(sessionID: id),
            .answer(sessionID: id, interactionID: UUID(), answer: .questionAnswers([QuestionAnswer(stepID: "q", selected: ["A", "B"], other: "C")])),
            .answer(sessionID: id, interactionID: UUID(), answer: .approvePlan(.autoAccept)),
            .answer(sessionID: id, interactionID: UUID(), answer: .denyWithNote("no")),
            .createSession(NewSessionRequest(goal: "g", projectID: nil, agent: .openCode, model: "m", effort: nil, createWorktree: false, fetchFirst: false)),
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
    func testDeltaPreservesConversationAfterWindowSlidesAndStreamingChanges() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let old = SessionTranscript(events: (0..<4).map {
            TranscriptEvent(id: String($0), content: .assistantMessage(text: "message \($0)", timestamp: date))
        })
        var next = old
        next.events = Array(old.events.dropFirst(2)) + [TranscriptEvent(id: "4", content: .assistantMessage(text: "new", timestamp: date))]
        next.streamingText = "typing"

        let delta = try XCTUnwrap(TranscriptDelta.make(from: old, to: next, baseRevision: 7))
        XCTAssertEqual(delta.dropCount, 2)
        XCTAssertEqual(delta.events.map(\.id), ["4"])
        XCTAssertEqual(delta.applying(to: old, revision: 7), next)
        XCTAssertNil(delta.applying(to: old, revision: 6), "a lost update must request a new snapshot")
    }

    func testRewrittenEarlierEventRequiresSnapshot() {
        let date = Date(timeIntervalSince1970: 1_000)
        let old = SessionTranscript(events: [TranscriptEvent(id: "1", content: .assistantMessage(text: "old", timestamp: date))])
        let next = SessionTranscript(events: [TranscriptEvent(id: "1", content: .assistantMessage(text: "rewritten", timestamp: date))])
        XCTAssertNil(TranscriptDelta.make(from: old, to: next, baseRevision: 1))
    }

    func testToolArgumentsDecodeScalarsAndCodexStrings() {
        let objectScalars = Data(#"{"command":"npm test","timeout":120,"nested":{"a":1}}"#.utf8)
        XCTAssertEqual(TranscriptEvent.Content.scalarArguments(objectScalars), ["command": "npm test", "timeout": "120"])

        let codexEncoded = Data(#""{\"cmd\":\"ls -la\"}""#.utf8)
        XCTAssertEqual(TranscriptEvent.Content.scalarArguments(codexEncoded), ["cmd": "ls -la"])
    }

    func testImagesAndHandoffsArePreserved() {
        let now = Date()
        XCTAssertEqual(
            TranscriptEvent.Content(.image(mimeType: "image/png", base64: "YWJj", filename: nil, timestamp: now)),
            .image(mimeType: "image/png", base64: "YWJj", filename: nil, timestamp: now)
        )
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
