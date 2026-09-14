import Foundation
import CryptoKit

/// Directional ChaChaPoly keys with strict per-direction counters.
///
/// A sealed frame is an 8-byte big-endian counter followed by the ciphertext
/// and tag; the counter doubles as the nonce. TCP delivers in order, so a
/// receiver demands exactly the next counter — a replayed, dropped, or
/// reordered frame fails and the connection is closed.
public struct SecureChannel: Sendable {
    public enum Role: Sendable {
        case client
        case server
    }

    public enum ChannelError: Error, Equatable, Sendable {
        case frameTooShort
        case unexpectedCounter(expected: UInt64, received: UInt64)
        case authenticationFailed
    }

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    init(shared: SharedSecret, salt: Data, role: Role) {
        let material = SymmetricKey(data: shared)
        let clientToServer = HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: salt, info: Data("c2s".utf8), outputByteCount: 32)
        let serverToClient = HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: salt, info: Data("s2c".utf8), outputByteCount: 32)
        switch role {
        case .client:
            sendKey = clientToServer
            receiveKey = serverToClient
        case .server:
            sendKey = serverToClient
            receiveKey = clientToServer
        }
    }

    public mutating func seal(_ plaintext: Data) throws -> Data {
        let counter = sendCounter
        sendCounter += 1
        let sealed = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: Self.nonce(counter))
        return Self.counterBytes(counter) + sealed.ciphertext + sealed.tag
    }

    public mutating func open(_ frame: Data) throws -> Data {
        guard frame.count >= 8 + 16 else { throw ChannelError.frameTooShort }
        let counter = frame.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard counter == receiveCounter else {
            throw ChannelError.unexpectedCounter(expected: receiveCounter, received: counter)
        }
        let body = frame.dropFirst(8)
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: Self.nonce(counter),
                ciphertext: body.dropLast(16),
                tag: body.suffix(16)
            )
            let plaintext = try ChaChaPoly.open(box, using: receiveKey)
            receiveCounter += 1
            return plaintext
        } catch {
            throw ChannelError.authenticationFailed
        }
    }

    private static func counterBytes(_ counter: UInt64) -> Data {
        var bigEndian = counter.bigEndian
        return Data(bytes: &bigEndian, count: 8)
    }

    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        try! ChaChaPoly.Nonce(data: Data(count: 4) + counterBytes(counter))
    }
}
