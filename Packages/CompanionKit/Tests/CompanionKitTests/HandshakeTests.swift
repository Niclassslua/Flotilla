import XCTest
import CryptoKit
@testable import CompanionKit

final class HandshakeTests: XCTestCase {
    private let macID = "mac-1"
    private let mac = CompanionIdentity()
    private let phone = CompanionIdentity()
    private let secret = Handshake.randomSecret()

    private func context(
        registered: [String: Data] = [:],
        revoked: Set<String> = [],
        secret: Data? = nil
    ) -> Handshake.ServerContext {
        let pairingSecret = secret ?? self.secret
        return Handshake.ServerContext(
            macID: macID,
            macName: "Studio",
            identity: mac,
            deviceKey: { id in
                if revoked.contains(id) { throw RejectReason.revoked }
                return registered[id]
            },
            verifyPairing: { transcript, proof in
                guard Handshake.isValidPairingProof(proof, transcript: transcript, secret: pairingSecret) else {
                    throw RejectReason.pairingInvalid
                }
            }
        )
    }

    private func hello(_ mode: HandshakeMode, secret: Data? = nil, identity: CompanionIdentity? = nil, macID: String? = nil) throws -> Handshake.ClientState {
        try Handshake.makeClientHello(
            mode: mode,
            macID: macID ?? self.macID,
            deviceID: "phone-1",
            deviceName: "iPhone",
            identity: identity ?? phone,
            pairingSecret: secret
        )
    }

    func testPairingProducesChannelsThatTalkBothWays() throws {
        let client = try hello(.pair, secret: secret)
        let server = try Handshake.respond(to: client.hello, context: context())
        var (clientChannel, serverHello) = try Handshake.completeClient(client, reply: server.reply, pinnedMacKey: mac.publicKey)
        var serverChannel = server.channel

        XCTAssertEqual(serverHello.macName, "Studio")
        let up = try clientChannel.seal(Data("hello mac".utf8))
        XCTAssertEqual(try serverChannel.open(up), Data("hello mac".utf8))
        let down = try serverChannel.seal(Data("hello phone".utf8))
        XCTAssertEqual(try clientChannel.open(down), Data("hello phone".utf8))
    }

    func testWrongPairingSecretIsRejected() throws {
        let client = try hello(.pair, secret: Handshake.randomSecret())
        XCTAssertThrowsError(try Handshake.respond(to: client.hello, context: context())) { error in
            XCTAssertEqual(error as? RejectReason, .pairingInvalid)
        }
    }

    func testResumeAcceptsTheRegisteredDeviceKey() throws {
        let client = try hello(.resume)
        let server = try Handshake.respond(to: client.hello, context: context(registered: ["phone-1": phone.publicKey]))
        XCTAssertNoThrow(try Handshake.completeClient(client, reply: server.reply, pinnedMacKey: mac.publicKey))
    }

    func testResumeWithAnotherKeyForTheSameDeviceIDIsRejected() throws {
        let impostor = try hello(.resume, identity: CompanionIdentity())
        XCTAssertThrowsError(try Handshake.respond(to: impostor.hello, context: context(registered: ["phone-1": phone.publicKey]))) { error in
            XCTAssertEqual(error as? RejectReason, .unknownDevice)
        }
    }

    func testResumeFromAnUnknownDeviceIsRejected() throws {
        let client = try hello(.resume)
        XCTAssertThrowsError(try Handshake.respond(to: client.hello, context: context())) { error in
            XCTAssertEqual(error as? RejectReason, .unknownDevice)
        }
    }

    func testRevokedDeviceIsRejected() throws {
        let client = try hello(.resume)
        XCTAssertThrowsError(try Handshake.respond(to: client.hello, context: context(registered: ["phone-1": phone.publicKey], revoked: ["phone-1"]))) { error in
            XCTAssertEqual(error as? RejectReason, .revoked)
        }
    }

    func testHelloForAnotherMacIsRejected() throws {
        let client = try hello(.pair, secret: secret, macID: "someone-else")
        XCTAssertThrowsError(try Handshake.respond(to: client.hello, context: context())) { error in
            XCTAssertEqual(error as? RejectReason, .wrongMac)
        }
    }

    func testClientRefusesAServerSignedByAnotherKey() throws {
        let client = try hello(.pair, secret: secret)
        let server = try Handshake.respond(to: client.hello, context: context())
        XCTAssertThrowsError(try Handshake.completeClient(client, reply: server.reply, pinnedMacKey: CompanionIdentity().publicKey)) { error in
            XCTAssertEqual(error as? HandshakeError, .macIdentityMismatch)
        }
    }

    func testClientSurfacesARejectReason() throws {
        let client = try hello(.pair, secret: secret)
        let reply = HandshakeFrame.serverReject(ServerReject(reason: .pairingExpired, supportedVersion: 1))
        XCTAssertThrowsError(try Handshake.completeClient(client, reply: reply, pinnedMacKey: mac.publicKey)) { error in
            XCTAssertEqual(error as? HandshakeError, .rejected(.pairingExpired))
        }
    }

    func testUnsupportedVersionIsRejected() throws {
        var client = try hello(.pair, secret: secret)
        var modified = client.hello
        modified.version = 99
        client = Handshake.ClientState(ephemeral: client.ephemeral, transcript: client.transcript, hello: modified)
        XCTAssertThrowsError(try Handshake.respond(to: client.hello, context: context())) { error in
            XCTAssertEqual(error as? RejectReason, .versionUnsupported)
        }
    }

    // MARK: - Channel integrity

    private func channels() throws -> (SecureChannel, SecureChannel) {
        let client = try hello(.pair, secret: secret)
        let server = try Handshake.respond(to: client.hello, context: context())
        let (clientChannel, _) = try Handshake.completeClient(client, reply: server.reply, pinnedMacKey: mac.publicKey)
        return (clientChannel, server.channel)
    }

    func testReplayedFrameIsRejected() throws {
        var (client, server) = try channels()
        let frame = try client.seal(Data("prompt".utf8))
        _ = try server.open(frame)
        XCTAssertThrowsError(try server.open(frame)) { error in
            XCTAssertEqual(error as? SecureChannel.ChannelError, .unexpectedCounter(expected: 1, received: 0))
        }
    }

    func testReorderedFrameIsRejected() throws {
        var (client, server) = try channels()
        _ = try client.seal(Data("first".utf8))
        let second = try client.seal(Data("second".utf8))
        XCTAssertThrowsError(try server.open(second))
    }

    func testTamperedFrameIsRejected() throws {
        var (client, server) = try channels()
        var frame = try client.seal(Data("delete session".utf8))
        frame[frame.count - 20] ^= 0x01
        XCTAssertThrowsError(try server.open(frame)) { error in
            XCTAssertEqual(error as? SecureChannel.ChannelError, .authenticationFailed)
        }
    }

    func testAFrameSealedForTheOtherDirectionDoesNotOpen() throws {
        var (client, _) = try channels()
        let frame = try client.seal(Data("hi".utf8))
        XCTAssertThrowsError(try client.open(frame))
    }
}
