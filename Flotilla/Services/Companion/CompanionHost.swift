import Foundation
import AppKit
import Observation
import SessionKit
import GitKit
import ProcessKit
import HooksKit
import CompanionKit

/// Hosts the iPhone companion link inside Flotilla: the listener, pairing,
/// paired devices, and the updates each connected phone receives.
@MainActor
@Observable
final class CompanionHost {
    enum Status: Equatable {
        case off
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    struct ActivePairing: Equatable {
        var link: String
        var payload: PairingPayload
    }

    private(set) var status: Status = .off
    private(set) var devices: [PairedDevice] = []
    private(set) var connectedDeviceIDs: Set<String> = []
    private(set) var pairing: ActivePairing?
    private(set) var addresses: [InterfaceAddress] = []
    private(set) var tailscaleDNSName: String?
    /// Set when the host couldn't load or create its identity.
    private(set) var setupError: String?

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? start() : stop()
        }
    }

    let macName: String

    @ObservationIgnored private let store: AppStore
    @ObservationIgnored private let storage: CompanionHostStorage
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let auth = CompanionAuthState()
    @ObservationIgnored private let bridge = ClaudePermissionBridge()
    @ObservationIgnored private let router: CompanionCommandRouter
    @ObservationIgnored private let adapters: CompanionAdapterRegistry
    @ObservationIgnored private let transcripts: CompanionTranscriptReader
    @ObservationIgnored private let socketURL: URL
    @ObservationIgnored private var server: CompanionServer?
    @ObservationIgnored private var identity: (macID: String, identity: CompanionIdentity)?
    @ObservationIgnored private var peers: [ObjectIdentifier: Peer] = [:]
    @ObservationIgnored private var publishTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptPublishTask: Task<Void, Never>?
    @ObservationIgnored private var lastFleet: FleetSnapshot?
    @ObservationIgnored private var pairingExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var cachedCatalog: CompanionKit.AgentCatalog = CompanionSnapshotBuilder.catalog()

    private static let enabledKey = "companion.enabled"
    static let pairingLifetime: TimeInterval = 5 * 60

    private final class Peer {
        let deviceID: String
        let session: ServerSideSession
        var subscribedSessionID: UUID?
        var lastTranscript: SessionTranscript?

        init(deviceID: String, session: ServerSideSession) {
            self.deviceID = deviceID
            self.session = session
        }
    }

    init(
        store: AppStore,
        gitService: any GitServiceProtocol,
        screenReader: (any SessionScreenReading)? = nil,
        supportDirectory: URL = TmuxSessionWrapping.defaultSupportDirectory(),
        storage: CompanionHostStorage = .default(),
        defaults: UserDefaults = .standard,
        macName: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    ) {
        self.store = store
        self.storage = storage
        self.defaults = defaults
        self.macName = macName
        self.socketURL = HookConfigurationWriter.companionSocketPath(supportDirectory: supportDirectory)
        let adapters = CompanionAdapterRegistry(support: supportDirectory)
        self.adapters = adapters
        self.router = CompanionCommandRouter(store: store, gitService: gitService, bridge: bridge, adapters: adapters)
        self.transcripts = CompanionTranscriptReader(registry: .flotilla())
        self.isEnabled = defaults.bool(forKey: Self.enabledKey) || Self.autoPairsForAutomation
        adapters.screen = { id in await screenReader?.readScreen(for: id) }
        adapters.send = { [weak store] id, data in store?.process(for: id)?.send(input: data) }
        adapters.bridge = bridge
        devices = storage.loadDevices()
        auth.setDevices(devices, revoked: storage.loadRevoked())

        bridge.onChange = { [weak self] in self?.publishFleetIfChanged() }
        adapters.onChange = { [weak self] in self?.publishFleetIfChanged() }
        bridge.onAllowNote = { [weak self] sessionID, note in
            Task { try? await self?.store.deliverMessage(note, to: sessionID) }
        }
        Task { [weak self] in
            let live = await CompanionSnapshotBuilder.catalog()
            guard let self else { return }
            self.cachedCatalog = live
            self.publishFleetIfChanged()
        }
        if isEnabled { start() }
    }

    // MARK: - Lifecycle

    private func start() {
        do {
            identity = try identity ?? storage.loadOrCreateHost()
            setupError = nil
        } catch {
            setupError = "The companion identity couldn't be created: \(error.localizedDescription)"
            status = .failed(setupError!)
            return
        }
        guard let identity else { return }
        refreshAddresses()
        bridge.start(socketURL: socketURL)

        let auth = self.auth
        let macName = self.macName
        let server = CompanionServer(
            context: {
                Handshake.ServerContext(
                    macID: identity.macID,
                    macName: macName,
                    identity: identity.identity,
                    deviceKey: { try auth.key(for: $0) },
                    verifyPairing: { try auth.verifyPairing(transcript: $0, proof: $1) }
                )
            },
            onPeer: { [weak self] peer in
                Task { @MainActor in self?.attach(peer) }
            },
            onStateChange: { [weak self] state in
                Task { @MainActor in self?.apply(state) }
            }
        )
        self.server = server
        server.start()
        startPublishing()
    }

    private func stop() {
        server?.stop()
        server = nil
        bridge.stop()
        adapters.close()
        publishTask?.cancel()
        publishTask = nil
        transcriptPublishTask?.cancel()
        transcriptPublishTask = nil
        Task { await transcripts.unwatchAll() }
        for peer in peers.values { peer.session.close() }
        peers = [:]
        connectedDeviceIDs = []
        cancelPairing()
        lastFleet = nil
        status = .off
    }

    func shutdown() {
        stop()
    }

    private func apply(_ state: CompanionServer.State) {
        guard isEnabled else { return }
        switch state {
        case .stopped: status = .off
        case .starting: status = .starting
        case .listening(let port):
            status = .listening(port: port)
            if pairing != nil {
                refreshPairingLink()
            } else if Self.autoPairsForAutomation {
                beginPairing()
            }
        case .failed(let message): status = .failed(message)
        }
    }

    // MARK: - Pairing

    func beginPairing() {
        guard isEnabled, let identity, case .listening = status else { return }
        let secret = Handshake.randomSecret()
        let expiresAt = Date().addingTimeInterval(Self.pairingLifetime)
        auth.beginPairing(secret: secret, expiresAt: expiresAt)
        refreshAddresses()
        let payload = PairingPayload(
            macID: identity.macID,
            macName: macName,
            macKey: identity.identity.publicKey,
            secret: secret,
            expiresAt: expiresAt,
            candidates: candidates()
        )
        pairing = (try? payload.link()).map { ActivePairing(link: $0, payload: payload) }
        writePairingLinkForAutomation()

        pairingExpiryTask?.cancel()
        pairingExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pairingLifetime))
            guard !Task.isCancelled else { return }
            self?.cancelPairing()
        }
        Task { await refreshTailscaleName() }
    }

    func cancelPairing() {
        auth.cancelPairing()
        pairing = nil
        pairingExpiryTask?.cancel()
        pairingExpiryTask = nil
    }

    private func refreshPairingLink() {
        guard var current = pairing else { return }
        current.payload.candidates = candidates()
        if let link = try? current.payload.link() {
            current.link = link
            pairing = current
            writePairingLinkForAutomation()
        }
    }

    /// Every address the phone may try, LAN first (docs/companion.md).
    func candidates() -> [HostCandidate] {
        guard case .listening(let port) = status else { return [] }
        var result: [HostCandidate] = []
        let bonjourHost = ProcessInfo.processInfo.hostName
        if bonjourHost.hasSuffix(".local") {
            result.append(HostCandidate(kind: .bonjour, host: bonjourHost, port: port))
        }
        for address in addresses {
            result.append(HostCandidate(kind: address.path == .lan ? .lan : .tailscale, host: address.address, port: port))
        }
        if let tailscaleDNSName {
            result.append(HostCandidate(kind: .tailscaleDNS, host: tailscaleDNSName, port: port))
        }
        return result
    }

    func refreshAddresses() {
        addresses = NetworkInterfaces.current()
    }

    /// The MagicDNS name, when the `tailscale` CLI can tell us (A4).
    private func refreshTailscaleName() async {
        let candidates = [
            PATHExecutableLocator().locate("tailscale"),
            URL(fileURLWithPath: "/Applications/Tailscale.app/Contents/MacOS/Tailscale"),
        ].compactMap { $0 }.filter { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let executable = candidates.first,
              let result = try? await ProcessCommandRunner().run(["status", "--json"], executable: executable, workingDirectory: FileManager.default.temporaryDirectory),
              result.exitCode == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] else { return }
        // A stopped Tailscale still reports its name; advertising it would
        // send the phone down a path that can't work.
        guard json["BackendState"] as? String == "Running",
              let selfNode = json["Self"] as? [String: Any],
              let name = selfNode["DNSName"] as? String, !name.isEmpty else {
            if tailscaleDNSName != nil {
                tailscaleDNSName = nil
                refreshPairingLink()
            }
            return
        }
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        guard trimmed != tailscaleDNSName else { return }
        tailscaleDNSName = trimmed
        refreshPairingLink()
    }

    /// `FLOTILLA_COMPANION_PAIRING_FILE` in a DEBUG or Ephemeral build enables the link and
    /// opens a pairing window at launch, for end-to-end runs.
    private static var autoPairsForAutomation: Bool {
        #if DEBUG || FLOTILLA_EPHEMERAL
        ProcessInfo.processInfo.environment["FLOTILLA_COMPANION_PAIRING_FILE"] != nil
        #else
        false
        #endif
    }

    /// DEBUG and Ephemeral builds write the current link where an end-to-end run can pick it
    /// up (`FLOTILLA_COMPANION_PAIRING_FILE`), since the simulator can't scan.
    private func writePairingLinkForAutomation() {
        #if DEBUG || FLOTILLA_EPHEMERAL
        guard let path = ProcessInfo.processInfo.environment["FLOTILLA_COMPANION_PAIRING_FILE"], let link = pairing?.link else { return }
        try? Data(link.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        #endif
    }

    // MARK: - Devices

    func revoke(_ deviceID: String) {
        devices.removeAll { $0.id == deviceID }
        var revoked = storage.loadRevoked()
        revoked.insert(deviceID)
        try? storage.saveRevoked(revoked)
        try? storage.saveDevices(devices)
        auth.setDevices(devices, revoked: revoked)
        for (key, peer) in peers where peer.deviceID == deviceID {
            peer.session.close()
            peers[key] = nil
        }
        connectedDeviceIDs = Set(peers.values.map(\.deviceID))
    }

    private func attach(_ connected: CompanionServer.Peer) {
        guard isEnabled else {
            connected.session.close()
            return
        }
        let hello = connected.hello
        if hello.mode == .pair {
            devices.removeAll { $0.id == hello.deviceID }
            devices.append(PairedDevice(id: hello.deviceID, name: hello.deviceName, publicKey: hello.deviceKey, pairedAt: .now, lastSeen: .now))
            var revoked = storage.loadRevoked()
            revoked.remove(hello.deviceID)
            try? storage.saveRevoked(revoked)
            auth.setDevices(devices, revoked: revoked)
            pairing = nil
            pairingExpiryTask?.cancel()
        } else if let index = devices.firstIndex(where: { $0.id == hello.deviceID }) {
            devices[index].lastSeen = .now
            devices[index].name = hello.deviceName
        }
        try? storage.saveDevices(devices)

        let peer = Peer(deviceID: hello.deviceID, session: connected.session)
        let key = ObjectIdentifier(peer)
        peers[key] = peer
        connectedDeviceIDs = Set(peers.values.map(\.deviceID))

        connected.session.onClose { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let sessionID = self.peers[key]?.subscribedSessionID
                self.peers[key] = nil
                self.connectedDeviceIDs = Set(self.peers.values.map(\.deviceID))
                if let sessionID {
                    await self.stopWatchingIfUnneeded(sessionID)
                }
            }
        }
        try? peer.session.send(.fleet(buildFleet()))

        Task { [weak self] in
            do {
                for try await message in connected.session.messages {
                    await self?.handle(message, from: peer)
                }
            } catch {}
        }
    }

    private func handle(_ message: ClientMessage, from peer: Peer) async {
        switch message {
        case .ping:
            try? peer.session.send(.pong)
        case .subscribe(let sessionID):
            peer.subscribedSessionID = sessionID
            peer.lastTranscript = nil
            await publishTranscript(to: peer)
            if let session = store.sessions.first(where: { $0.id == sessionID }) {
                await transcripts.watch(session)
            }
        case .unsubscribe:
            if let sessionID = peer.subscribedSessionID {
                await stopWatchingIfUnneeded(sessionID)
            }
            peer.subscribedSessionID = nil
            peer.lastTranscript = nil
        case .request(let id, let request):
            let response = await router.handle(request)
            try? peer.session.send(.response(id: id, response))
            publishFleetIfChanged()
        }
    }

    // MARK: - Publishing

    private func startPublishing() {
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                // A dead pane's endpoint is gone; polling it only logs failures.
                await self.adapters.refresh(self.store.sessions.filter { self.store.process(for: $0.id) != nil })
                self.bridge.retractResolved { sessionID in
                    self.store.sessions.first { $0.id == sessionID }?.status == .waitingForInput
                }
                guard !self.peers.isEmpty else { continue }
                self.publishFleetIfChanged()
                for peer in self.peers.values where peer.subscribedSessionID != nil { await self.publishTranscript(to: peer) }
            }
        }
        transcriptPublishTask?.cancel()
        transcriptPublishTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.transcripts.changes {
                guard !Task.isCancelled else { return }
                for peer in self.peers.values where peer.subscribedSessionID != nil {
                    await self.publishTranscript(to: peer)
                }
            }
        }
    }

    private func stopWatchingIfUnneeded(_ sessionID: UUID) async {
        guard !peers.values.contains(where: { $0.subscribedSessionID == sessionID }) else { return }
        await transcripts.unwatch(sessionID)
    }

    private func publishFleetIfChanged() {
        guard !peers.isEmpty else { return }
        let fleet = buildFleet()
        guard fleet != lastFleet else { return }
        lastFleet = fleet
        for peer in peers.values {
            try? peer.session.send(.fleet(fleet))
        }
    }

    private func publishTranscript(to peer: Peer) async {
        guard let sessionID = peer.subscribedSessionID,
              let session = store.sessions.first(where: { $0.id == sessionID }) else { return }
        let transcript: SessionTranscript
        if let adapter = adapters.adapter(for: session), session.agent == .openCode {
            transcript = adapter.transcript
        } else {
            guard var native = await transcripts.transcript(for: session, ifChangedSince: nil) else { return }
            if let adapter = adapters.adapter(for: session) {
                native.streamingText = adapter.transcript.streamingText
                native.retryAttempt = adapter.transcript.retryAttempt
                native.events += adapter.transcript.events.filter { if case .turnFailed = $0.content { true } else { false } }
            }
            transcript = native
        }
        guard transcript != peer.lastTranscript else { return }
        guard peer.subscribedSessionID == sessionID else { return }
        peer.lastTranscript = transcript
        try? peer.session.send(.transcript(sessionID: sessionID, transcript))
    }

    func buildFleet() -> FleetSnapshot {
        CompanionSnapshotBuilder.snapshot(
            macID: identity?.macID ?? "",
            macName: macName,
            sessions: store.sessions,
            projects: store.projects,
            catalog: cachedCatalog,
            context: { session in
                CompanionSnapshotBuilder.SessionContext(
                    diffStat: store.diffStatStore.stat(for: session.id),
                    handoffTargets: store.handoffTargets(for: session),
                    isProcessLive: store.process(for: session.id) != nil && session.status != .crashed,
                    answerable: session.agent == .claudeCode ? bridge.pending(for: session.id) : adapters.pending(session) + bridge.pending(for: session.id)
                )
            }
        )
    }
}
