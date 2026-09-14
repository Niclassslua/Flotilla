import Foundation
import CryptoKit

/// A long-lived Ed25519 identity — the Mac's, or a paired phone's.
public struct CompanionIdentity: Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey

    public init(privateKey: Curve25519.Signing.PrivateKey = .init()) {
        self.privateKey = privateKey
    }

    public init(rawRepresentation: Data) throws {
        privateKey = try .init(rawRepresentation: rawRepresentation)
    }

    public var publicKey: Data { privateKey.publicKey.rawRepresentation }
    public var rawRepresentation: Data { privateKey.rawRepresentation }
}

public enum HandshakeMode: String, Codable, Sendable {
    /// First connection: proves possession of the pairing secret.
    case pair
    /// Later connections: signs with the registered device key.
    case resume
}

/// First frame, phone → Mac. Plaintext; every field is bound into the proof.
public struct ClientHello: Codable, Sendable, Equatable {
    public var version: Int
    public var mode: HandshakeMode
    public var macID: String
    public var deviceID: String
    public var deviceName: String
    public var deviceKey: Data
    public var ephemeralKey: Data
    public var nonce: Data
    public var proof: Data
}

/// Second frame, Mac → phone, on success.
public struct ServerHello: Codable, Sendable, Equatable {
    public var version: Int
    public var macName: String
    public var ephemeralKey: Data
    public var nonce: Data
    public var signature: Data
}

public enum RejectReason: String, Codable, Sendable, Error, CaseIterable {
    case pairingExpired
    case pairingInvalid
    case unknownDevice
    case revoked
    case versionUnsupported
    case wrongMac
    case malformed
}

/// Second frame, Mac → phone, on failure.
public struct ServerReject: Codable, Sendable, Equatable {
    public var reason: RejectReason
    public var supportedVersion: Int
}

/// The plaintext handshake frames share one envelope so a receiver can tell
/// them apart before decoding.
public enum HandshakeFrame: Codable, Sendable, Equatable {
    case clientHello(ClientHello)
    case serverHello(ServerHello)
    case serverReject(ServerReject)
}

public enum HandshakeError: Error, Equatable, Sendable {
    case rejected(RejectReason)
    /// The Mac's signature doesn't verify against the pinned key: either the
    /// Mac was reinstalled or something is impersonating it.
    case macIdentityMismatch
    case malformedFrame
    case versionMismatch(remote: Int)
}

/// Both sides of the handshake. Pure functions over keys and bytes; the
/// transport only moves the frames.
public enum Handshake {
    static let label = Data("flotilla-companion-v1".utf8)

    static func clientTranscript(macID: String, deviceID: String, deviceKey: Data, ephemeral: Data, nonce: Data) -> Data {
        var data = label
        for field in [Data(macID.utf8), Data(deviceID.utf8), deviceKey, ephemeral, nonce] {
            var length = UInt32(field.count).bigEndian
            data.append(Data(bytes: &length, count: 4))
            data.append(field)
        }
        return Data(SHA256.hash(data: data))
    }

    static func serverTranscript(clientTranscript: Data, ephemeral: Data, nonce: Data) -> Data {
        Data(SHA256.hash(data: clientTranscript + ephemeral + nonce))
    }

    // MARK: Client

    public struct ClientState: Sendable {
        let ephemeral: Curve25519.KeyAgreement.PrivateKey
        let transcript: Data
        public let hello: ClientHello
    }

    /// Builds the hello. `pairingSecret` is required for `.pair`, and the
    /// identity signs for `.resume`.
    public static func makeClientHello(
        mode: HandshakeMode,
        macID: String,
        deviceID: String,
        deviceName: String,
        identity: CompanionIdentity,
        pairingSecret: Data?
    ) throws -> ClientState {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let nonce = randomBytes(32)
        let transcript = clientTranscript(
            macID: macID,
            deviceID: deviceID,
            deviceKey: identity.publicKey,
            ephemeral: ephemeral.publicKey.rawRepresentation,
            nonce: nonce
        )
        let proof: Data
        switch mode {
        case .pair:
            guard let pairingSecret else { throw HandshakeError.malformedFrame }
            proof = Data(HMAC<SHA256>.authenticationCode(for: transcript, using: SymmetricKey(data: pairingSecret)))
        case .resume:
            proof = try identity.privateKey.signature(for: transcript)
        }
        let hello = ClientHello(
            version: CompanionProtocol.version,
            mode: mode,
            macID: macID,
            deviceID: deviceID,
            deviceName: deviceName,
            deviceKey: identity.publicKey,
            ephemeralKey: ephemeral.publicKey.rawRepresentation,
            nonce: nonce,
            proof: proof
        )
        return ClientState(ephemeral: ephemeral, transcript: transcript, hello: hello)
    }

    /// Verifies the Mac's answer against the pinned key and derives the channel.
    public static func completeClient(_ state: ClientState, reply: HandshakeFrame, pinnedMacKey: Data) throws -> (SecureChannel, ServerHello) {
        switch reply {
        case .serverReject(let reject):
            throw HandshakeError.rejected(reject.reason)
        case .clientHello:
            throw HandshakeError.malformedFrame
        case .serverHello(let hello):
            guard hello.version == CompanionProtocol.version else {
                throw HandshakeError.versionMismatch(remote: hello.version)
            }
            let serverTranscript = serverTranscript(clientTranscript: state.transcript, ephemeral: hello.ephemeralKey, nonce: hello.nonce)
            guard let macKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pinnedMacKey),
                  macKey.isValidSignature(hello.signature, for: serverTranscript) else {
                throw HandshakeError.macIdentityMismatch
            }
            guard let serverEphemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: hello.ephemeralKey),
                  let shared = try? state.ephemeral.sharedSecretFromKeyAgreement(with: serverEphemeral) else {
                throw HandshakeError.malformedFrame
            }
            let channel = SecureChannel(shared: shared, salt: serverTranscript, role: .client)
            return (channel, hello)
        }
    }

    // MARK: Server

    /// What the Mac knows about devices and pairing, consulted mid-handshake.
    public struct ServerContext: Sendable {
        public var macID: String
        public var macName: String
        public var identity: CompanionIdentity
        /// Returns the registered key for a device, or `nil` if unknown, or
        /// throws `.revoked`.
        public var deviceKey: @Sendable (String) throws -> Data?
        /// Validates and consumes the current pairing secret against a proof.
        public var verifyPairing: @Sendable (_ transcript: Data, _ proof: Data) throws -> Void

        public init(
            macID: String,
            macName: String,
            identity: CompanionIdentity,
            deviceKey: @escaping @Sendable (String) throws -> Data?,
            verifyPairing: @escaping @Sendable (Data, Data) throws -> Void
        ) {
            self.macID = macID
            self.macName = macName
            self.identity = identity
            self.deviceKey = deviceKey
            self.verifyPairing = verifyPairing
        }
    }

    public struct ServerResult: Sendable {
        public let channel: SecureChannel
        public let reply: HandshakeFrame
        public let hello: ClientHello
    }

    /// Checks a hello and produces either the reply plus channel, or throws a
    /// `RejectReason` the caller sends back.
    public static func respond(to hello: ClientHello, context: ServerContext) throws -> ServerResult {
        guard hello.version == CompanionProtocol.version else { throw RejectReason.versionUnsupported }
        guard hello.macID == context.macID else { throw RejectReason.wrongMac }
        guard hello.deviceKey.count == 32, hello.ephemeralKey.count == 32, hello.nonce.count == 32 else {
            throw RejectReason.malformed
        }
        let transcript = clientTranscript(
            macID: hello.macID,
            deviceID: hello.deviceID,
            deviceKey: hello.deviceKey,
            ephemeral: hello.ephemeralKey,
            nonce: hello.nonce
        )
        switch hello.mode {
        case .pair:
            try context.verifyPairing(transcript, hello.proof)
        case .resume:
            guard let registered = try context.deviceKey(hello.deviceID) else { throw RejectReason.unknownDevice }
            guard registered == hello.deviceKey,
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: registered),
                  key.isValidSignature(hello.proof, for: transcript) else {
                throw RejectReason.unknownDevice
            }
        }
        guard let clientEphemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: hello.ephemeralKey) else {
            throw RejectReason.malformed
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let nonce = randomBytes(32)
        let serverTranscript = serverTranscript(clientTranscript: transcript, ephemeral: ephemeral.publicKey.rawRepresentation, nonce: nonce)
        let signature = try context.identity.privateKey.signature(for: serverTranscript)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: clientEphemeral)
        let reply = HandshakeFrame.serverHello(ServerHello(
            version: CompanionProtocol.version,
            macName: context.macName,
            ephemeralKey: ephemeral.publicKey.rawRepresentation,
            nonce: nonce,
            signature: signature
        ))
        return ServerResult(channel: SecureChannel(shared: shared, salt: serverTranscript, role: .server), reply: reply, hello: hello)
    }

    /// Constant-time check of a pairing proof against a secret.
    public static func isValidPairingProof(_ proof: Data, transcript: Data, secret: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: transcript, using: SymmetricKey(data: secret))
    }

    static func randomBytes(_ count: Int) -> Data {
        SymmetricKey(size: .init(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }

    public static func randomSecret() -> Data { randomBytes(32) }
}
