import XCTest
import Network
import SessionKit
import CompanionKit
@testable import FlotillaCompanion

/// A Mac stand-in: a real `CompanionServer` on loopback that answers requests
/// and can push fleet snapshots.
private final class FakeMac: @unchecked Sendable {
    let lock = NSLock()
    let identity = CompanionIdentity()
    let macID = "mac-test"
    var secret: Data? = Handshake.randomSecret()
    var devices: [String: Data] = [:]
    var revoked: Set<String> = []
    var peers: [ServerSideSession] = []
    var received: [CompanionRequest] = []
    var fleet: FleetSnapshot
    private(set) var server: CompanionServer!
    private(set) var port: UInt16 = 0

    init(sessions: [CompanionSession]) {
        fleet = FleetSnapshot(macID: macID, macName: "Test Mac", sessions: sessions, projects: [], catalog: .fallback)
    }

    func start() async throws {
        let ready = AsyncStream<UInt16>.makeStream()
        server = CompanionServer(
            advertisesBonjour: false,
            context: { [self] in
                Handshake.ServerContext(
                    macID: macID,
                    macName: "Test Mac",
                    identity: identity,
                    deviceKey: { id in
                        try self.lock.withLock {
                            if self.revoked.contains(id) { throw RejectReason.revoked }
                            return self.devices[id]
                        }
                    },
                    verifyPairing: { transcript, proof in
                        try self.lock.withLock {
                            guard let secret = self.secret, Handshake.isValidPairingProof(proof, transcript: transcript, secret: secret) else {
                                throw RejectReason.pairingInvalid
                            }
                            self.secret = nil
                        }
                    }
                )
            },
            onPeer: { [self] peer in
                let snapshot = lock.withLock {
                    devices[peer.hello.deviceID] = peer.hello.deviceKey
                    peers.append(peer.session)
                    return fleet
                }
                try? peer.session.send(.fleet(snapshot))
                Task {
                    for try await message in peer.session.messages {
                        guard case .request(let id, let request) = message else { continue }
                        self.lock.withLock { self.received.append(request) }
                        let response: CompanionResponse = switch request {
                        case .answer: .answer(.accepted)
                        case .sendPrompt(_, let text) where text == "fail": .failure(message: "Nope")
                        default: .ok
                        }
                        try? peer.session.send(.response(id: id, response))
                    }
                }
            },
            onStateChange: { state in
                if case .listening(let port) = state { ready.continuation.yield(port) }
            }
        )
        server.start(preferredPort: nil)
        for await port in ready.stream {
            self.port = port
            break
        }
    }

    func push(_ snapshot: FleetSnapshot) {
        let targets = lock.withLock {
            fleet = snapshot
            return peers
        }
        targets.forEach { try? $0.send(.fleet(snapshot)) }
    }

    var payload: PairingPayload {
        PairingPayload(
            macID: macID,
            macName: "Test Mac",
            macKey: identity.publicKey,
            secret: lock.withLock { secret } ?? Data(count: 32),
            expiresAt: .now.addingTimeInterval(300),
            candidates: [
                HostCandidate(kind: .tailscale, host: "127.0.0.1", port: 9),
                HostCandidate(kind: .lan, host: "127.0.0.1", port: port),
            ]
        )
    }
}

@MainActor
final class RemoteCompanionTests: XCTestCase {
    private func session(status: SessionStatus = .working) -> CompanionSession {
        CompanionSession(id: UUID(), title: "Fix tests", agent: .claudeCode, model: "opus", status: status, hasWorktree: false, isProcessLive: true, updatedAt: .now)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func testPairingDeliversTheFleetAndRequestsRoundTrip() async throws {
        let sample = session()
        let mac = FakeMac(sessions: [sample])
        try await mac.start()
        let data = RemoteCompanionDataSource(store: .temporary(), identityStore: InMemoryDeviceIdentityStore(), deviceName: "Test iPhone")
        data.setActive(true)

        var seen: [ConnectTarget: AttemptStatus] = [:]
        let macID = try await data.pair(with: mac.payload) { target, status in seen[target] = status }

        XCTAssertEqual(macID, mac.macID)
        await waitUntil { !data.sessions(on: macID).isEmpty }
        XCTAssertEqual(data.sessions(on: macID).map(\.id), [sample.id])
        XCTAssertTrue(data.macs.first?.isReachable ?? false)
        if case .connected(let path, _) = data.macs.first?.connection {
            XCTAssertEqual(path, .lan, "the dead Tailscale address must lose to the working LAN one")
        } else {
            XCTFail("expected a connection")
        }

        try await data.sendPrompt("Carry on", to: sample.id)
        XCTAssertEqual(mac.lock.withLock { mac.received }.last, .sendPrompt(sessionID: sample.id, text: "Carry on"))
        do {
            try await data.sendPrompt("fail", to: sample.id)
            XCTFail("a failure response must throw")
        } catch let error as CompanionActionError {
            XCTAssertEqual(error.message, "Nope")
        }
        XCTAssertEqual(data.transcript(for: sample.id).queuedPrompts.count, 1, "a prompt to a working session shows as queued")
    }

    func testACardAnsweredOnTheMacIsShownAsSuch() async throws {
        var waiting = session(status: .waitingForInput)
        waiting.waitingReason = .permission
        let mac = FakeMac(sessions: [waiting])
        let card = PendingInteraction(kind: .permission(PermissionRequest(tool: "Bash", summary: "ls")))
        mac.fleet.pending = [waiting.id: [card]]
        try await mac.start()
        let data = RemoteCompanionDataSource(store: .temporary(), identityStore: InMemoryDeviceIdentityStore(), deviceName: "Test iPhone")
        data.setActive(true)
        _ = try await data.pair(with: mac.payload) { _, _ in }
        await waitUntil { !data.pendingInteractions(for: waiting.id).isEmpty }

        var answered = mac.fleet
        answered.pending = [:]
        answered.sessions[0].status = .working
        mac.push(answered)
        await waitUntil { data.pendingInteractions(for: waiting.id).first?.resolution != nil }

        XCTAssertEqual(data.pendingInteractions(for: waiting.id).first?.resolution, .answeredOnMac(outcome: "Answered"))
    }

    func testCodexQuestionSelectionsAndFreeTextReachTheMacThroughThePhoneStore() async throws {
        var waiting = session(status: .waitingForInput)
        waiting.agent = .codexCLI
        let card = PendingInteraction(kind: .question([
            .init(id: "0", header: "Language", prompt: "Which language?", options: [.init(label: "Python"), .init(label: "Ruby")], allowsMultiple: false, allowsFreeText: true),
            .init(id: "1", header: "Name", prompt: "Project name?", options: [], allowsMultiple: false, allowsFreeText: true)
        ]))
        let mac = FakeMac(sessions: [waiting])
        mac.fleet.pending = [waiting.id: [card]]
        try await mac.start()
        defer { mac.server.stop(); mac.lock.withLock { mac.peers }.forEach { $0.close() } }
        let data = RemoteCompanionDataSource(store: .temporary(), identityStore: InMemoryDeviceIdentityStore(), deviceName: "Test iPhone")
        data.setActive(true)
        defer { data.setActive(false) }
        let domain = "CodexQuestionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = CompanionStore(data: data, defaults: defaults)
        _ = try await store.pair(with: mac.payload) { _, _ in }
        await waitUntil { !store.pendingInteractions(for: waiting.id).isEmpty }
        XCTAssertEqual(store.pendingInteractions(for: waiting.id).map(\.kind), [card.kind])
        let answer = InteractionAnswer.questionAnswers([.init(stepID: "0", selected: ["Ruby"]), .init(stepID: "1", selected: [], other: "PhoneProject")])
        let outcome = await store.answer(card.id, in: waiting.id, with: answer)
        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(mac.lock.withLock { mac.received }.last, .answer(sessionID: waiting.id, interactionID: card.id, answer: answer))
        var updated = mac.fleet
        updated.pending = [:]
        updated.sessions[0].status = .working
        mac.push(updated)
        await waitUntil { store.pendingInteractions(for: waiting.id).isEmpty }
        XCTAssertTrue(store.pendingInteractions(for: waiting.id).isEmpty)
        XCTAssertNil(store.actionError)
    }

    func testRevokedPhoneNeedsRepairing() async throws {
        let mac = FakeMac(sessions: [])
        try await mac.start()
        let store = PairedMacStore.temporary()
        let identity = InMemoryDeviceIdentityStore()
        let data = RemoteCompanionDataSource(store: store, identityStore: identity, deviceName: "Test iPhone")
        data.setActive(true)
        let macID = try await data.pair(with: mac.payload) { _, _ in }

        let deviceID = try identity.loadOrCreate().deviceID
        mac.lock.withLock {
            mac.devices[deviceID] = nil
            mac.revoked.insert(deviceID)
        }
        mac.lock.withLock { mac.peers }.forEach { $0.close() }

        await waitUntil(10) { data.macs.first?.connection == .needsRepairing(.revoked) }
        XCTAssertEqual(data.macs.first { $0.id == macID }?.connection, .needsRepairing(.revoked))
    }

    func testExpiredCodeIsDiagnosedWithoutConnecting() async {
        let data = RemoteCompanionDataSource(store: .temporary(), identityStore: InMemoryDeviceIdentityStore(), deviceName: "Test iPhone")
        var payload = FakeMac(sessions: []).payload
        payload.expiresAt = .now.addingTimeInterval(-1)
        do {
            _ = try await data.pair(with: payload) { _, _ in }
            XCTFail("expired code must fail")
        } catch let failure as PairingFailure {
            XCTAssertEqual(failure.diagnosis.headline, .expired)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

final class ConnectionDiagnosisTests: XCTestCase {
    private let lan = ConnectTarget(path: .lan, label: "192.168.1.20", endpoint: .hostPort(host: "192.168.1.20", port: 48620))
    private let tailnet = ConnectTarget(path: .tailscale, label: "100.101.5.3", endpoint: .hostPort(host: "100.101.5.3", port: 48620))

    func testUnreachableOnBothPathsExplainsEach() {
        let diagnosis = ConnectionDiagnosis.diagnose(
            error: ConnectError.unreachable([:]),
            attempts: [lan: .failed(.timedOut), tailnet: .failed(.unreachable("POSIXErrorCode: No route to host"))],
            offeredPaths: [.lan, .tailscale],
            phoneHasTailnet: false,
            localNetworkDenied: false
        )
        XCTAssertEqual(diagnosis.headline, .unreachable)
        let tailscale = diagnosis.paths.first { $0.path == .tailscale }!
        XCTAssertEqual(tailscale.outcome, .failed(["100.101.5.3": "no route to host"]))
        XCTAssertTrue(diagnosis.advice(for: tailscale).first!.contains("isn't connected on this iPhone"))
        let lanReport = diagnosis.paths.first { $0.path == .lan }!
        XCTAssertTrue(diagnosis.advice(for: lanReport).contains { $0.contains("same Wi-Fi") })
    }

    func testMissingTailscaleAddressIsReportedAsNotOffered() {
        let diagnosis = ConnectionDiagnosis.diagnose(
            error: ConnectError.unreachable([:]),
            attempts: [lan: .failed(.localNetworkDenied)],
            offeredPaths: [.lan],
            phoneHasTailnet: true,
            localNetworkDenied: false
        )
        XCTAssertEqual(diagnosis.headline, .localNetworkDenied)
        XCTAssertTrue(diagnosis.localNetworkDenied)
        let tailscale = diagnosis.paths.first { $0.path == .tailscale }!
        XCTAssertEqual(tailscale.outcome, .notOffered)
        XCTAssertTrue(diagnosis.advice(for: tailscale).first!.contains("isn't connected on the Mac"))
    }

    func testRejectsMapToSpecificHeadlines() {
        func headline(_ error: Error) -> ConnectionDiagnosis.Headline {
            ConnectionDiagnosis.diagnose(error: error, attempts: [:], offeredPaths: [], phoneHasTailnet: false, localNetworkDenied: false).headline
        }
        XCTAssertEqual(headline(ConnectError.handshake(.rejected(.pairingInvalid))), .alreadyUsed)
        XCTAssertEqual(headline(ConnectError.handshake(.rejected(.pairingExpired))), .expired)
        XCTAssertEqual(headline(ConnectError.handshake(.macIdentityMismatch)), .identityMismatch)
        XCTAssertEqual(headline(ConnectError.handshake(.rejected(.versionUnsupported))), .versionMismatch)
        XCTAssertEqual(headline(PairingPayload.LinkError.malformed), .other("The pairing link is incomplete. Copy it again from the Mac."))
    }
}

final class TranscriptLayoutTests: XCTestCase {
    func testConsecutiveToolsGroupAndTheUnansweredOneIsInFlight() {
        let now = Date()
        let events: [TranscriptEvent.Content] = [
            .userMessage(text: "Go", timestamp: now),
            .toolUse(id: "a", tool: "Read", input: ["file_path": "a.swift"], timestamp: now),
            .toolResult(toolUseID: "a", output: "ok", isError: false, timestamp: now),
            .toolUse(id: "b", tool: "Bash", input: ["command": "make test"], timestamp: now),
        ]
        let transcript = events.enumerated().map { TranscriptEvent(id: String($0.offset), content: $0.element) }
        let items = TranscriptLayout.items(from: transcript)
        XCTAssertEqual(items.count, 2)
        guard case .toolGroup(_, let calls) = items[1] else { return XCTFail("expected a tool group") }
        XCTAssertEqual(calls.map(\.id), ["a", "b"])
        XCTAssertEqual(TranscriptLayout.inFlightCall(in: transcript)?.summary, "Bash · make test")
    }
}
