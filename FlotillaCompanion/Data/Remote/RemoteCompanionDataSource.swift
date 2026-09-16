import Foundation
import Observation
import UIKit
import SessionKit
import CompanionKit

/// A pairing attempt that didn't work, with a diagnosis for the error screen.
struct PairingFailure: Error {
    var diagnosis: ConnectionDiagnosis
}

/// The real data source: one `MacConnection` per paired Mac.
@MainActor
@Observable
final class RemoteCompanionDataSource: CompanionDataSource {
    private(set) var connections: [MacConnection] = []
    let browser = LANBrowser()

    @ObservationIgnored private let store: PairedMacStore
    @ObservationIgnored private let identityStore: any DeviceIdentityStoring
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var desiredFocus: UUID?

    init(
        store: PairedMacStore = .default(),
        identityStore: any DeviceIdentityStoring = KeychainDeviceIdentityStore(),
        deviceName: String = UIDevice.current.name
    ) {
        self.store = store
        self.identityStore = identityStore
        self.deviceName = deviceName
        connections = store.loadMacs().map { makeConnection($0) }
    }

    private func makeConnection(_ record: PairedMacRecord) -> MacConnection {
        let connection = MacConnection(
            record: record,
            cache: store.loadCache(record.macID),
            identityStore: identityStore,
            browser: browser,
            deviceName: deviceName
        )
        let macID = record.macID
        let cacheWriter = CompanionCacheWriter(store: store, macID: macID)
        connection.onRecordChange = { [weak self] _ in self?.saveRecords() }
        connection.onCacheChange = { cache, revision in Task { await cacheWriter.schedule(cache, revision: revision) } }
        connection.onCacheFlush = { cache, revision in Task { await cacheWriter.flush(cache, revision: revision) } }
        connection.onCacheDiscard = { await cacheWriter.discard() }
        connection.onFleetChange = { [weak self] in self?.applyFocus() }
        return connection
    }

    private func saveRecords() {
        store.saveMacs(connections.map(\.record))
    }

    private func connection(_ macID: MacHost.ID) -> MacConnection? {
        connections.first { $0.record.macID == macID }
    }

    private func connection(forSession sessionID: UUID) -> MacConnection? {
        connections.first { $0.fleet?.sessions.contains { $0.id == sessionID } ?? false }
    }

    private func connected(forSession sessionID: UUID) throws -> MacConnection {
        guard let connection = connection(forSession: sessionID), connection.isConnected else {
            throw CompanionActionError.unreachable
        }
        return connection
    }

    // MARK: - Reads

    var macs: [MacHost] {
        connections.map {
            MacHost(id: $0.record.macID, name: $0.record.name, connection: $0.state, lastSeen: $0.record.lastSeen)
        }
    }

    var supportsPairing: Bool { true }

    func sessions(on macID: MacHost.ID) -> [CompanionSession] {
        guard let connection = connection(macID) else { return [] }
        return (connection.fleet?.sessions ?? []).map { session in
            var session = session
            session.reviewAcknowledged = connection.acknowledgedReviews.contains(session.id)
            return session
        }
    }

    func projects(on macID: MacHost.ID) -> [ProjectSummary] {
        connection(macID)?.fleet?.projects ?? []
    }

    func catalog(on macID: MacHost.ID) -> AgentCatalog {
        connection(macID)?.fleet?.catalog ?? .fallback
    }

    func session(_ id: CompanionSession.ID) -> CompanionSession? {
        guard let connection = connection(forSession: id),
              var session = connection.fleet?.sessions.first(where: { $0.id == id }) else { return nil }
        session.reviewAcknowledged = connection.acknowledgedReviews.contains(id)
        return session
    }

    func macID(for sessionID: CompanionSession.ID) -> MacHost.ID? {
        connection(forSession: sessionID)?.record.macID
    }

    func transcript(for sessionID: CompanionSession.ID) -> SessionTranscript {
        connection(forSession: sessionID)?.transcript(for: sessionID) ?? SessionTranscript()
    }

    func pendingInteractions(for sessionID: CompanionSession.ID) -> [PendingInteraction] {
        connection(forSession: sessionID)?.pending(for: sessionID) ?? []
    }

    func fleetReceivedAt(_ macID: MacHost.ID) -> Date? {
        connection(macID)?.fleetReceivedAt
    }

    func transcriptReceivedAt(_ sessionID: CompanionSession.ID) -> Date? {
        connection(forSession: sessionID)?.transcriptsReceivedAt[sessionID]
    }

    func diff(for sessionID: CompanionSession.ID, commitHash: String?) -> Remote<[FileDiff]> {
        connection(forSession: sessionID)?.diff(for: sessionID, commitHash: commitHash) ?? .failed("The session isn't available.")
    }

    func commits(for sessionID: CompanionSession.ID) -> Remote<[CommitSummary]> {
        connection(forSession: sessionID)?.commits[sessionID] ?? .loading
    }

    func fileContents(at path: String, in sessionID: CompanionSession.ID) -> Remote<String?> {
        connection(forSession: sessionID)?.fileContents(at: path, in: sessionID) ?? .loading
    }

    func loadDiff(for sessionID: CompanionSession.ID, commitHash: String?) async {
        await connection(forSession: sessionID)?.loadDiff(for: sessionID, commitHash: commitHash)
    }

    func loadCommits(for sessionID: CompanionSession.ID) async {
        await connection(forSession: sessionID)?.loadCommits(for: sessionID)
    }

    func loadFile(at path: String, in sessionID: CompanionSession.ID) async {
        await connection(forSession: sessionID)?.loadFile(at: path, in: sessionID)
    }

    func focus(on sessionID: CompanionSession.ID?) {
        desiredFocus = sessionID
        applyFocus()
    }

    private func applyFocus() {
        let owner = desiredFocus.flatMap { connection(forSession: $0) }
        for connection in connections {
            connection.focus(on: connection === owner ? desiredFocus : nil)
        }
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active, !connections.isEmpty { browser.start() }
        if !active { browser.stop() }
        connections.forEach { $0.setActive(active) }
    }

    // MARK: - Intents

    func answer(_ interactionID: PendingInteraction.ID, in sessionID: CompanionSession.ID, with answer: InteractionAnswer) async throws -> AnswerOutcome {
        try await connected(forSession: sessionID).answer(interactionID, in: sessionID, with: answer)
    }

    func sendPrompt(_ text: String, to sessionID: CompanionSession.ID) async throws {
        let connection = try connected(forSession: sessionID)
        connection.acknowledgeReview(sessionID)
        try await connection.sendPrompt(text, to: sessionID)
    }

    func stop(_ sessionID: CompanionSession.ID) async throws {
        try await connected(forSession: sessionID).perform(.stop(sessionID: sessionID))
    }

    func createSession(_ request: NewSessionRequest, on macID: MacHost.ID) async throws -> CompanionSession.ID {
        guard let connection = connection(macID), connection.isConnected else { throw CompanionActionError.unreachable }
        switch try await connection.request(.createSession(request)) {
        case .created(let sessionID): return sessionID
        case .failure(let message): throw CompanionActionError(message: message)
        default: throw CompanionActionError(message: "Unexpected response from the Mac.")
        }
    }

    func handoff(_ sessionID: CompanionSession.ID, _ request: HandoffRequest) async throws {
        try await connected(forSession: sessionID).perform(.handoff(sessionID: sessionID, request))
    }

    func restart(_ sessionID: CompanionSession.ID) async throws {
        try await connected(forSession: sessionID).perform(.restart(sessionID: sessionID))
    }

    func delete(_ sessionID: CompanionSession.ID, removeWorktree: Bool) async throws {
        try await connected(forSession: sessionID).perform(.delete(sessionID: sessionID, removeWorktree: removeWorktree))
    }

    func acknowledgeReview(_ sessionID: CompanionSession.ID) {
        connection(forSession: sessionID)?.acknowledgeReview(sessionID)
    }

    // MARK: - Pairing

    func pair(with payload: PairingPayload, progress: @escaping @MainActor (ConnectTarget, AttemptStatus) -> Void) async throws -> MacHost.ID {
        browser.start()
        let offered = Set(payload.candidates.map(\.kind.path))
        guard !payload.isExpired() else {
            throw PairingFailure(diagnosis: ConnectionDiagnosis.diagnose(
                error: ConnectError.handshake(.rejected(.pairingExpired)), attempts: [:], offeredPaths: offered,
                phoneHasTailnet: NetworkInterfaces.hasTailnetAddress, localNetworkDenied: browser.permission == .denied, payloadExpired: true
            ))
        }

        var targets: [ConnectTarget] = []
        if let discovered = browser.endpoint(forMac: payload.macID) {
            targets.append(ConnectTarget(path: .lan, label: "\(discovered.name) (Bonjour)", endpoint: discovered.endpoint))
        }
        targets += payload.candidates.compactMap(ConnectTarget.init)

        let log = AttemptLog()
        do {
            let identity = try identityStore.loadOrCreate()
            let name = deviceName
            let result = try await CompanionClient.connect(
                to: targets,
                hello: {
                    try Handshake.makeClientHello(mode: .pair, macID: payload.macID, deviceID: identity.deviceID, deviceName: name, identity: identity.identity, pairingSecret: payload.secret)
                },
                pinnedMacKey: payload.macKey,
                onAttempt: { target, status in
                    log.record(target, status)
                    Task { @MainActor in progress(target, status) }
                }
            )
            let record = PairedMacRecord(
                macID: payload.macID,
                name: result.serverHello.macName,
                macKey: payload.macKey,
                candidates: payload.candidates,
                pairedAt: .now,
                lastSeen: .now
            )
            if let existing = connection(payload.macID) {
                existing.disconnect()
                await existing.onCacheDiscard()
                connections.removeAll { $0 === existing }
            }
            let connection = makeConnection(record)
            connections.append(connection)
            saveRecords()
            // Adopt first: activating an unconnected Mac starts a second handshake.
            connection.adopt(result.session, target: result.target, macName: result.serverHello.macName)
            connection.setActive(isActive)
            return payload.macID
        } catch {
            throw PairingFailure(diagnosis: ConnectionDiagnosis.diagnose(
                error: error,
                attempts: log.snapshot,
                offeredPaths: offered,
                phoneHasTailnet: NetworkInterfaces.hasTailnetAddress,
                localNetworkDenied: browser.permission == .denied
            ))
        }
    }

    func removeMac(_ macID: MacHost.ID) {
        guard let connection = connection(macID) else { return }
        connection.setActive(false)
        Task { await connection.onCacheDiscard() }
        connections.removeAll { $0 === connection }
        saveRecords()
    }

    func reconnect(_ macID: MacHost.ID) {
        connection(macID)?.reconnectNow()
    }

    func clearCachedTranscripts(on macID: MacHost.ID) {
        connection(macID)?.clearCachedTranscripts()
    }

    func clearAllCachedTranscripts() {
        connections.forEach { $0.clearCachedTranscripts() }
    }

    /// Connection details for the diagnostics screen.
    func diagnostics(for macID: MacHost.ID) -> (attempts: [ConnectTarget: AttemptStatus], diagnosis: ConnectionDiagnosis?, record: PairedMacRecord)? {
        guard let connection = connection(macID) else { return nil }
        return (connection.lastAttempts, connection.lastDiagnosis, connection.record)
    }
}
