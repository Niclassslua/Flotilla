import XCTest
import Network
@testable import CompanionKit

/// Real server and client over loopback TCP: the path a phone takes, minus
/// the network in between.
final class LoopbackTests: XCTestCase {
    private final class MacState: @unchecked Sendable {
        let lock = NSLock()
        let identity = CompanionIdentity()
        var secret: Data? = Handshake.randomSecret()
        var devices: [String: Data] = [:]
        var sessions: [ServerSideSession] = []
    }

    private var mac: MacState!
    private var server: CompanionServer!
    private var port: UInt16 = 0

    override func setUp() async throws {
        mac = MacState()
        let mac = self.mac!
        let listening = expectation(description: "listening")
        let portBox = PortBox()
        server = CompanionServer(
            advertisesBonjour: false,
            context: {
                Handshake.ServerContext(
                    macID: "mac-1",
                    macName: "Studio",
                    identity: mac.identity,
                    deviceKey: { id in mac.lock.withLock { mac.devices[id] } },
                    verifyPairing: { transcript, proof in
                        try mac.lock.withLock {
                            guard let secret = mac.secret,
                                  Handshake.isValidPairingProof(proof, transcript: transcript, secret: secret) else {
                                throw RejectReason.pairingInvalid
                            }
                            mac.secret = nil
                        }
                    }
                )
            },
            onPeer: { peer in
                mac.lock.withLock {
                    mac.devices[peer.hello.deviceID] = peer.hello.deviceKey
                    mac.sessions.append(peer.session)
                }
                Task {
                    do {
                        for try await message in peer.session.messages where message == .ping {
                            try peer.session.send(.pong)
                        }
                    } catch {}
                }
            },
            onStateChange: { state in
                if case .listening(let port) = state {
                    portBox.value = port
                    listening.fulfill()
                }
            }
        )
        server.start(preferredPort: nil)
        await fulfillment(of: [listening], timeout: 5)
        port = portBox.value
    }

    override func tearDown() {
        server.stop()
    }

    private final class PortBox: @unchecked Sendable { var value: UInt16 = 0 }

    private var loopback: ConnectTarget {
        ConnectTarget(path: .lan, label: "127.0.0.1", endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!))
    }

    private func connect(
        mode: HandshakeMode,
        identity: CompanionIdentity,
        secret: Data?,
        targets: [ConnectTarget]? = nil
    ) async throws -> ClientSideSession {
        let pinned = mac.identity.publicKey
        return try await CompanionClient.connect(
            to: targets ?? [loopback],
            hello: {
                try Handshake.makeClientHello(mode: mode, macID: "mac-1", deviceID: "phone-1", deviceName: "iPhone", identity: identity, pairingSecret: secret)
            },
            pinnedMacKey: pinned
        ).session
    }


    func testPairThenResumeThenExchangeMessages() async throws {
        let phone = CompanionIdentity()
        let secret = try XCTUnwrap(mac.secret)

        let paired = try await connect(mode: .pair, identity: phone, secret: secret)
        var pairedMessages = paired.messages.makeAsyncIterator()
        try paired.send(.ping)
        let pairedReply = try await pairedMessages.next()
        XCTAssertEqual(pairedReply, .pong)
        paired.close()

        let resumed = try await connect(mode: .resume, identity: phone, secret: nil)
        var resumedMessages = resumed.messages.makeAsyncIterator()
        try resumed.send(.ping)
        let resumedReply = try await resumedMessages.next()
        XCTAssertEqual(resumedReply, .pong)

        // The Mac can push unprompted.
        let macSide = try XCTUnwrap(mac.lock.withLock { mac.sessions.last })
        let snapshot = FleetSnapshot(macID: "mac-1", macName: "Studio", sessions: [], projects: [], catalog: .fallback)
        try macSide.send(.fleet(snapshot))
        let pushed = try await resumedMessages.next()
        XCTAssertEqual(pushed, .fleet(snapshot))
        resumed.close()
    }

    func testPairingSecretIsSingleUse() async throws {
        let secret = try XCTUnwrap(mac.secret)
        _ = try await connect(mode: .pair, identity: CompanionIdentity(), secret: secret)
        do {
            _ = try await connect(mode: .pair, identity: CompanionIdentity(), secret: secret)
            XCTFail("second pairing with the same secret should fail")
        } catch let error as ConnectError {
            XCTAssertEqual(error, .handshake(.rejected(.pairingInvalid)))
        }
    }

    func testUnknownDeviceCannotResume() async throws {
        do {
            _ = try await connect(mode: .resume, identity: CompanionIdentity(), secret: nil)
            XCTFail("resume without pairing should fail")
        } catch let error as ConnectError {
            XCTAssertEqual(error, .handshake(.rejected(.unknownDevice)))
        }
    }

    func testAClosedPortIsReportedAsUnreachableAndAnotherTargetWins() async throws {
        let dead = ConnectTarget(path: .tailscale, label: "dead", endpoint: .hostPort(host: "127.0.0.1", port: 9))
        let secret = try XCTUnwrap(mac.secret)
        let session = try await connect(mode: .pair, identity: CompanionIdentity(), secret: secret, targets: [dead, loopback])
        var messages = session.messages.makeAsyncIterator()
        try session.send(.ping)
        let reply = try await messages.next()
        XCTAssertEqual(reply, .pong)

        do {
            _ = try await connect(mode: .resume, identity: CompanionIdentity(), secret: nil, targets: [dead])
            XCTFail("dead target should be unreachable")
        } catch let error as ConnectError {
            guard case .unreachable(let failures) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertNotNil(failures[dead])
        }
    }
}
