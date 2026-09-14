import Foundation
import CompanionKit

/// A phone paired with this Mac.
struct PairedDevice: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var publicKey: Data
    var pairedAt: Date
    var lastSeen: Date?
}

/// This Mac's companion identity and paired devices, on disk.
///
/// The identity key is a 0600 file rather than a Keychain item: debug builds
/// are ad-hoc signed, and a Keychain ACL tied to that signature would prompt
/// for access after every rebuild (docs/companion.md, A5).
struct CompanionHostStorage: Sendable {
    let directory: URL

    struct HostRecord: Codable {
        var macID: String
        var privateKey: Data
    }

    static func `default`() -> CompanionHostStorage {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if FLOTILLA_EPHEMERAL
        let folder = "Flotilla Ephemeral"
        #else
        let folder = "Flotilla"
        #endif
        return CompanionHostStorage(directory: support.appendingPathComponent(folder).appendingPathComponent("Companion", isDirectory: true))
    }

    private var hostURL: URL { directory.appendingPathComponent("host.json") }
    private var devicesURL: URL { directory.appendingPathComponent("devices.json") }
    private var revokedURL: URL { directory.appendingPathComponent("revoked.json") }

    func loadOrCreateHost() throws -> (macID: String, identity: CompanionIdentity) {
        if let data = try? Data(contentsOf: hostURL),
           let record = try? JSONDecoder().decode(HostRecord.self, from: data),
           let identity = try? CompanionIdentity(rawRepresentation: record.privateKey) {
            return (record.macID, identity)
        }
        let identity = CompanionIdentity()
        let record = HostRecord(macID: UUID().uuidString, privateKey: identity.rawRepresentation)
        try write(JSONEncoder().encode(record), to: hostURL)
        return (record.macID, identity)
    }

    func loadDevices() -> [PairedDevice] {
        guard let data = try? Data(contentsOf: devicesURL) else { return [] }
        return (try? CompanionJSON.decode([PairedDevice].self, from: data)) ?? []
    }

    func saveDevices(_ devices: [PairedDevice]) throws {
        try write(CompanionJSON.encode(devices), to: devicesURL)
    }

    /// Device ids removed on this Mac, kept so a removed phone is told so
    /// instead of being treated as a stranger.
    func loadRevoked() -> Set<String> {
        guard let data = try? Data(contentsOf: revokedURL) else { return [] }
        return (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
    }

    func saveRevoked(_ ids: Set<String>) throws {
        try write(JSONEncoder().encode(ids), to: revokedURL)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// What the handshake consults from the listener's queue: registered keys and
/// the current pairing secret. Locked, because the server calls it off the
/// main actor.
final class CompanionAuthState: @unchecked Sendable {
    struct Pairing {
        var secret: Data
        var expiresAt: Date
        var failedAttempts: Int
    }

    static let maximumFailedAttempts = 5

    private let lock = NSLock()
    private var deviceKeys: [String: Data] = [:]
    private var revoked: Set<String> = []
    private var pairing: Pairing?
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func setDevices(_ devices: [PairedDevice], revoked: Set<String>) {
        lock.withLock {
            deviceKeys = Dictionary(devices.map { ($0.id, $0.publicKey) }, uniquingKeysWith: { _, last in last })
            self.revoked = revoked
        }
    }

    func key(for deviceID: String) throws -> Data? {
        try lock.withLock {
            if let key = deviceKeys[deviceID] { return key }
            if revoked.contains(deviceID) { throw RejectReason.revoked }
            return nil
        }
    }

    func beginPairing(secret: Data, expiresAt: Date) {
        lock.withLock { pairing = Pairing(secret: secret, expiresAt: expiresAt, failedAttempts: 0) }
    }

    func cancelPairing() {
        lock.withLock { pairing = nil }
    }

    var hasActivePairing: Bool {
        lock.withLock { pairing.map { now() < $0.expiresAt } ?? false }
    }

    /// Consumes the secret on success; burns it after too many failures.
    func verifyPairing(transcript: Data, proof: Data) throws {
        try lock.withLock {
            guard var current = pairing else { throw RejectReason.pairingInvalid }
            guard now() < current.expiresAt else {
                pairing = nil
                throw RejectReason.pairingExpired
            }
            guard Handshake.isValidPairingProof(proof, transcript: transcript, secret: current.secret) else {
                current.failedAttempts += 1
                pairing = current.failedAttempts >= Self.maximumFailedAttempts ? nil : current
                throw RejectReason.pairingInvalid
            }
            pairing = nil
        }
    }
}
