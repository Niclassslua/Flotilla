import Foundation
import Security
import CompanionKit

/// This phone's identity: a device id and an Ed25519 key, in the Keychain.
struct DeviceIdentity: Sendable {
    let deviceID: String
    let identity: CompanionIdentity
}

protocol DeviceIdentityStoring: Sendable {
    func loadOrCreate() throws -> DeviceIdentity
}

struct KeychainDeviceIdentityStore: DeviceIdentityStoring {
    var service = "com.niclassslua.flotilla.companion"
    var account = "device-identity"

    private struct Record: Codable {
        var deviceID: String
        var privateKey: Data
    }

    func loadOrCreate() throws -> DeviceIdentity {
        if let data = read(), let record = try? JSONDecoder().decode(Record.self, from: data),
           let identity = try? CompanionIdentity(rawRepresentation: record.privateKey) {
            return DeviceIdentity(deviceID: record.deviceID, identity: identity)
        }
        let identity = CompanionIdentity()
        let record = Record(deviceID: UUID().uuidString, privateKey: identity.rawRepresentation)
        try write(JSONEncoder().encode(record))
        return DeviceIdentity(deviceID: record.deviceID, identity: identity)
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func read() -> Data? {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func write(_ data: Data) throws {
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CompanionActionError(message: "This iPhone's identity couldn't be saved to the Keychain (\(status)).")
        }
    }
}

struct InMemoryDeviceIdentityStore: DeviceIdentityStoring {
    let identity = DeviceIdentity(deviceID: UUID().uuidString, identity: CompanionIdentity())
    func loadOrCreate() throws -> DeviceIdentity { identity }
}

/// What the phone remembers about a paired Mac. Nothing here is secret: the
/// Mac's public key is pinned, the addresses are where to look.
struct PairedMacRecord: Codable, Hashable, Sendable {
    var macID: String
    var name: String
    var macKey: Data
    var candidates: [HostCandidate]
    var pairedAt: Date
    var lastSeen: Date
    /// The address that last worked, tried first next time.
    var lastConnected: HostCandidate?
    var repairReason: String?
}

/// Paired Macs and each Mac's last fleet and transcripts, so an unreachable
/// Mac still shows its cached, read-only state (spec: offline behaviour).
struct PairedMacStore: Sendable {
    let directory: URL

    static func `default`() -> PairedMacStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return PairedMacStore(directory: support.appendingPathComponent("Companion", isDirectory: true))
    }

    static func temporary() -> PairedMacStore {
        PairedMacStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("companion-\(UUID().uuidString)", isDirectory: true))
    }

    private var macsURL: URL { directory.appendingPathComponent("macs.json") }
    private func cacheURL(_ macID: String) -> URL { directory.appendingPathComponent("cache-\(macID).json") }

    struct Cache: Codable, Sendable {
        var fleet: FleetSnapshot?
        var transcripts: [UUID: SessionTranscript]
    }

    func loadMacs() -> [PairedMacRecord] {
        guard let data = try? Data(contentsOf: macsURL) else { return [] }
        return (try? CompanionJSON.decode([PairedMacRecord].self, from: data)) ?? []
    }

    func saveMacs(_ records: [PairedMacRecord]) {
        write(try? CompanionJSON.encode(records), to: macsURL)
    }

    func loadCache(_ macID: String) -> Cache? {
        guard let data = try? Data(contentsOf: cacheURL(macID)) else { return nil }
        return try? CompanionJSON.decode(Cache.self, from: data)
    }

    func saveCache(_ cache: Cache, for macID: String) {
        write(try? CompanionJSON.encode(cache), to: cacheURL(macID))
    }

    func removeCache(_ macID: String) {
        try? FileManager.default.removeItem(at: cacheURL(macID))
    }

    private func write(_ data: Data?, to url: URL) {
        guard let data else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Serializes cache snapshots away from the UI actor and collapses bursts of
/// transcript tokens into one atomic write. Flushing on backgrounding avoids
/// leaving a pending snapshot behind when iOS suspends the app.
actor CompanionCacheWriter {
    private let store: PairedMacStore
    private let macID: String
    private var pending: PairedMacStore.Cache?
    private var latestRevision: UInt64 = 0
    private var isDiscarded = false
    private var writeTask: Task<Void, Never>?

    init(store: PairedMacStore, macID: String) {
        self.store = store
        self.macID = macID
    }

    func schedule(_ cache: PairedMacStore.Cache, revision: UInt64) {
        guard !isDiscarded, revision >= latestRevision else { return }
        latestRevision = revision
        pending = cache
        writeTask?.cancel()
        writeTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            flushPending()
        }
    }

    func flush(_ cache: PairedMacStore.Cache, revision: UInt64) {
        guard !isDiscarded, revision >= latestRevision else { return }
        latestRevision = revision
        pending = cache
        flushPending()
    }

    private func flushPending() {
        writeTask?.cancel()
        writeTask = nil
        guard let pending else { return }
        self.pending = nil
        store.saveCache(pending, for: macID)
    }

    func discard() {
        isDiscarded = true
        writeTask?.cancel()
        writeTask = nil
        pending = nil
        store.removeCache(macID)
    }
}
