import AppKit
import CompanionKit
import Foundation
import GitKit
import HooksKit
import Observation
import os
import ProcessKit
import SessionKit
import SettingsKit

/// Hosts the iPhone companion link inside Flotilla: the listener, pairing,
/// paired devices, and the updates each connected phone receives.
@MainActor
@Observable
final class CompanionHost {
    private static let syncLog = Logger(subsystem: "com.niclassslua.flotilla", category: "CompanionSync")
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
    private(set) var recentlyPairedDevice: PairedDevice?
    private(set) var addresses: [InterfaceAddress] = []
    private(set) var tailscaleDNSName: String?
    /// Set when the host couldn't load or create its identity.
    private(set) var setupError: String?

    enum HandyStatus: Equatable, Sendable {
        case checking
        case connected(model: String?)
        case disconnected(reason: String)
    }

    private(set) var handyStatus: HandyStatus = .checking
    @ObservationIgnored private let localSpeech: any HandySpeechServing = HandySpeechClient()

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
    @ObservationIgnored private var activeReads = 0
    @ObservationIgnored private var readGeneration: UInt64 = 0
    @ObservationIgnored private var queuedReads: [(CompanionRequest, UInt64, Peer)] = []
    @ObservationIgnored private var publishTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptPublishTask: Task<Void, Never>?
    @ObservationIgnored private var handyCheckTask: Task<CompanionSpeechEvent, Never>?
    @ObservationIgnored private var pairingExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var cachedCatalog: CompanionKit.AgentCatalog
    @ObservationIgnored private var lastPublishedCandidates: [HostCandidate]?
    @ObservationIgnored private let presence = PresenceMonitor()
    @ObservationIgnored private var lastAttentionSessions: [UUID: CompanionSession] = [:]
    /// Reads the Mac's currently configured OpenCode plan, so the catalog
    /// sent to the phone can scope a live model query to it — without this,
    /// OpenCode has nothing to enumerate against and falls back to bare ids.
    @ObservationIgnored private let openCodeSubscription: () -> OpenCodeSubscription

    private static let enabledKey = "companion.enabled"
    static let pairingLifetime: TimeInterval = 5 * 60
    /// How many one-second publish ticks between `tailscale status` calls.
    private static let tailscaleRefreshTicks = 15

    private final class Peer {
        let deviceID: String
        let session: ServerSideSession
        let speech: any HandySpeechServing
        var subscribedSessionID: UUID?
        var subscriptionGeneration: UInt64 = 0
        var lastFleet: FleetSnapshot?
        var fleetRevision: UInt64 = 0
        var lastTranscript: SessionTranscript?
        var unsendableTranscript: SessionTranscript?
        var transcriptRevision: UInt64 = 0
        var isPublishingTranscript = false
        var transcriptPublishPending = false

        init(deviceID: String, session: ServerSideSession,
             speech: any HandySpeechServing = HandySpeechClient()) {
            self.deviceID = deviceID
            self.session = session
            self.speech = speech
        }
    }

    init(
        store: AppStore,
        gitService: any GitServiceProtocol,
        screenReader: (any SessionScreenReading)? = nil,
        supportDirectory: URL = TmuxSessionWrapping.defaultSupportDirectory(),
        storage: CompanionHostStorage = .default(),
        defaults: UserDefaults = .standard,
        macName: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
        openCodeSubscription: @escaping () -> OpenCodeSubscription = { .none }
    ) {
        self.store = store
        self.storage = storage
        self.defaults = defaults
        self.macName = macName
        self.openCodeSubscription = openCodeSubscription
        cachedCatalog = CompanionSnapshotBuilder.catalog(openCodeSubscription: openCodeSubscription())

        socketURL = HookConfigurationWriter.companionSocketPath(supportDirectory: supportDirectory)
        let adapters = CompanionAdapterRegistry(support: supportDirectory)
        self.adapters = adapters
        router = CompanionCommandRouter(store: store, gitService: gitService, bridge: bridge, adapters: adapters)
        transcripts = CompanionTranscriptReader(registry: .flotilla())
        isEnabled = defaults.bool(forKey: Self.enabledKey) || Self.autoPairsForAutomation
        adapters.screen = { id in await screenReader?.readScreen(for: id) }
        adapters.send = { [weak store] id, data in store?.process(for: id)?.send(input: data) }
        adapters.bridge = bridge
        devices = storage.loadDevices()
        auth.setDevices(devices, revoked: storage.loadRevoked())

        bridge.onChange = { [weak self] in self?.publishFleetIfChanged() }
        adapters.onChange = { [weak self] in
            guard let self else { return }
            self.publishFleetIfChanged()
            Task { [weak self] in
                guard let self else { return }
                for peer in self.peers.values where peer.subscribedSessionID != nil {
                    await self.publishTranscript(to: peer)
                }
            }
        }
        bridge.onAllowNote = { [weak self] sessionID, note in
            Task { try? await self?.store.deliverMessage(note, to: sessionID) }
        }
        Task { [weak self] in
            let live = await CompanionSnapshotBuilder.catalog(openCodeSubscription: openCodeSubscription())
            guard let self else { return }
            self.cachedCatalog = live
            self.publishFleetIfChanged()
        }
        if isEnabled {
            start()
        }
        Task { [weak self] in
            await self?.checkHandyConnection()
        }
    }

    // MARK: - Lifecycle

    private func start() {
        #if FLOTILLA_EPHEMERAL
        let liveSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flotilla", isDirectory: true)
        let liveSocket = HookConfigurationWriter.companionSocketPath(supportDirectory: liveSupport)
        guard socketURL.resolvingSymlinksInPath() != liveSocket.resolvingSymlinksInPath() else {
            setupError = "Ephemeral refused to use the running Flotilla app's companion socket."
            status = .failed(setupError!)
            return
        }
        #endif
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
        if !bridge.start(socketURL: socketURL) {
            setupError = "The companion permission bridge couldn't start because its socket is already in use. Another Flotilla instance may be running."
        }

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
        lastAttentionSessions = Dictionary(uniqueKeysWithValues: buildFleet().sessions.map { ($0.id, $0) })
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
        for peer in peers.values {
            peer.session.close()
        }
        peers = [:]
        readGeneration += 1
        activeReads = 0
        queuedReads.removeAll()
        lastAttentionSessions = [:]
        connectedDeviceIDs = []
        cancelPairing()
        recentlyPairedDevice = nil
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
        case let .listening(port):
            status = .listening(port: port)
            if pairing != nil {
                refreshPairingLink()
            } else if Self.autoPairsForAutomation {
                beginPairing()
            }
        case let .failed(message): status = .failed(message)
        }
    }

    // MARK: - Pairing

    func beginPairing() {
        guard isEnabled, let identity, case .listening = status else { return }
        recentlyPairedDevice = nil
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
        lastPublishedCandidates = payload.candidates
        writePairingLinkForAutomation()

        pairingExpiryTask?.cancel()
        pairingExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pairingLifetime))
            guard !Task.isCancelled else { return }
            self?.cancelPairing()
        }
        Task { [weak self] in
            await self?.refreshTailscaleName()
            self?.publishAddressUpdateIfNeeded()
        }
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
        guard case let .listening(port) = status else { return [] }
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
              let name = selfNode["DNSName"] as? String, !name.isEmpty
        else {
            if tailscaleDNSName != nil {
                tailscaleDNSName = nil
                publishAddressUpdateIfNeeded()
            }
            return
        }
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        guard trimmed != tailscaleDNSName else { return }
        tailscaleDNSName = trimmed
        publishAddressUpdateIfNeeded()
    }

    /// Sends already-paired phones the Mac's current addresses whenever they
    /// change (Tailscale connecting after pairing, an IP changing, …), so
    /// reaching the Mac from a new network doesn't require re-pairing.
    private func publishAddressUpdateIfNeeded() {
        let current = candidates()
        guard !current.isEmpty, current != lastPublishedCandidates else { return }
        lastPublishedCandidates = current
        if pairing != nil {
            refreshPairingLink()
        }
        for peer in peers.values {
            try? peer.session.send(.addressUpdate(candidates: current))
        }
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
            let device = PairedDevice(id: hello.deviceID, name: hello.deviceName, publicKey: hello.deviceKey, pairedAt: .now, lastSeen: .now)
            devices.append(device)
            recentlyPairedDevice = device
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
        Self.syncLog.info("peer attached device=\(hello.deviceID, privacy: .public) mode=\(String(describing: hello.mode), privacy: .public) peers=\(self.peers.count)")

        connected.session.onClose { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let sessionID = self.peers[key]?.subscribedSessionID
                let departing = self.peers[key]
                self.peers[key] = nil
                self.queuedReads.removeAll { ObjectIdentifier($0.2) == key }
                self.connectedDeviceIDs = Set(self.peers.values.map(\.deviceID))
                if let departing { await departing.speech.close() }
                if let sessionID {
                    await self.stopWatchingIfUnneeded(sessionID)
                }
            }
        }
        sendFleetSnapshot(to: peer)
        Task { [weak self] in
            guard let self else { return }
            await self.adapters.refresh(self.store.sessions.filter { self.store.process(for: $0.id) != nil })
        }

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
        case .speechCapabilities:
            try? peer.session.send(.speech(await peer.speech.capabilities()))
        case let .speechStart(request):
            try? peer.session.send(.speech(await peer.speech.start(request)))
        case let .speechAudio(requestID, sequence, pcm):
            guard pcm.count <= 3_200 else {
                try? peer.session.send(.speech(.failed(requestID: requestID, code: "invalidAudio",
                    message: "Audio chunk is too large.", retryable: false)))
                return
            }
            try? peer.session.send(.speech(await peer.speech.audio(requestID: requestID,
                                                                    sequence: sequence, pcm: pcm)))
        case let .speechFinish(requestID):
            try? peer.session.send(.speech(await peer.speech.finish(requestID: requestID)))
        case let .speechCancel(requestID):
            try? peer.session.send(.speech(await peer.speech.cancel(requestID: requestID)))
        case .ping:
            try? peer.session.send(.pong)
        case let .subscribe(sessionID):
            let previous = peer.subscribedSessionID
            peer.subscriptionGeneration += 1
            peer.subscribedSessionID = sessionID
            peer.lastTranscript = nil
            peer.unsendableTranscript = nil
            peer.transcriptRevision = 0
            if let previous, previous != sessionID {
                await stopWatchingIfUnneeded(previous)
            }
            await publishTranscript(to: peer)
            if let session = store.sessions.first(where: { $0.id == sessionID }) {
                await transcripts.watch(session)
            }
        case let .resyncTranscript(sessionID):
            guard peer.subscribedSessionID == sessionID else { return }
            peer.lastTranscript = nil
            peer.unsendableTranscript = nil
            await publishTranscript(to: peer)
        case .resyncFleet:
            sendFleetSnapshot(to: peer)
        case .unsubscribe:
            let previous = peer.subscribedSessionID
            peer.subscriptionGeneration += 1
            peer.subscribedSessionID = nil
            peer.lastTranscript = nil
            peer.unsendableTranscript = nil
            if let previous {
                await stopWatchingIfUnneeded(previous)
            }
        case let .request(id, request):
            if case .diff = request {
                handleRead(request, id: id, from: peer)
                return
            }
            if case .commits = request {
                handleRead(request, id: id, from: peer)
                return
            }
            if case .file = request {
                handleRead(request, id: id, from: peer)
                return
            }
            if case .filePage = request {
                handleRead(request, id: id, from: peer)
                return
            }
            let response = await router.handle(request)
            try? peer.session.send(.response(id: id, response))
            publishFleetIfChanged()
        }
    }

    private func handleRead(_ request: CompanionRequest, id: UInt64, from peer: Peer) {
        guard activeReads < 2 else {
            guard queuedReads.count < 16 else {
                try? peer.session.send(.response(id: id, .failure(message: "The Mac is busy loading other files. Try again shortly.")))
                return
            }
            queuedReads.append((request, id, peer))
            return
        }
        activeReads += 1
        let generation = readGeneration
        Task { [weak self, weak peer] in
            guard let self else { return }
            defer {
                if self.readGeneration == generation {
                    self.readFinished()
                }
            }
            guard let peer else { return }
            let response = await self.router.handle(request)
            do {
                try peer.session.send(.response(id: id, response))
            } catch TransportError.frameTooLarge {
                try? peer.session.send(.response(id: id, .failure(message: "This change is too large to send to the iPhone in one piece. Open it on the Mac.")))
            } catch {}
        }
    }

    private func readFinished() {
        activeReads -= 1
        while !queuedReads.isEmpty {
            let (request, id, peer) = queuedReads.removeFirst()
            guard peers.values.contains(where: { $0 === peer }) else { continue }
            handleRead(request, id: id, from: peer)
            break
        }
    }

    // MARK: - Publishing

    private func startPublishing() {
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                tick += 1
                // A dead pane's endpoint is gone; polling it only logs failures.
                if !self.peers.isEmpty {
                    await self.adapters.refresh(self.store.sessions.filter { self.store.process(for: $0.id) != nil })
                }
                self.bridge.retractResolved { sessionID in
                    self.store.sessions.first { $0.id == sessionID }?.status == .waitingForInput
                }
                self.refreshAddresses()
                if tick.isMultiple(of: Self.tailscaleRefreshTicks) {
                    await self.refreshTailscaleName()
                }
                self.publishAddressUpdateIfNeeded()
                self.publishAttentionTransitions()
                guard !self.peers.isEmpty else { continue }
                self.publishFleetIfChanged()
                for peer in self.peers.values where peer.subscribedSessionID != nil {
                    await self.publishTranscript(to: peer)
                }
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
        for peer in peers.values {
            guard peer.lastFleet != fleet else { continue }
            if let old = peer.lastFleet {
                let delta = FleetDelta.make(from: old, to: fleet, baseRevision: peer.fleetRevision)
                Self.syncLog.info("send fleet delta device=\(peer.deviceID, privacy: .public) base=\(delta.baseRevision) revision=\(delta.revision) oldSessions=\(old.sessions.count) newSessions=\(fleet.sessions.count) ordered=\(delta.orderedIDs.count) changed=\(delta.changed.count) projects=\(fleet.projects.count)")
                guard (try? peer.session.send(.fleetDelta(delta))) != nil else { continue }
                peer.fleetRevision = delta.revision
            } else {
                Self.syncLog.info("send initial fleet device=\(peer.deviceID, privacy: .public) sessions=\(fleet.sessions.count) projects=\(fleet.projects.count) sessionIDs=\(fleet.sessions.map { $0.id.uuidString }, privacy: .public)")
                guard (try? peer.session.send(.fleet(fleet))) != nil else { continue }
                peer.fleetRevision = 0
            }
            peer.lastFleet = fleet
        }
    }

    private func publishAttentionTransitions() {
        let fleet = buildFleet()
        let previous = lastAttentionSessions
        lastAttentionSessions = Dictionary(uniqueKeysWithValues: fleet.sessions.map { ($0.id, $0) })
        guard presence.isAway, !peers.isEmpty else { return }
        for session in fleet.sessions {
            guard let old = previous[session.id], old.status != session.status,
                  let status = session.status,
                  status == .waitingForInput || status == .readyForReview || status == .crashed else { continue }
            let permission = fleet.pending[session.id]?.first { card in
                if case .permission = card.kind {
                    return true
                }
                return false
            }
            let summary = session.attentionSummary ?? {
                switch status {
                case .waitingForInput: "Needs your input"
                case .readyForReview: "Ready for review"
                case .crashed: "Session crashed"
                case .working: "Working"
                }
            }()
            let event = SessionAttentionEvent(
                sessionID: session.id, title: session.title, status: status,
                summary: summary, permissionID: permission?.id
            )
            for peer in peers.values {
                try? peer.session.send(.attention(event))
            }
        }
    }

    private func sendFleetSnapshot(to peer: Peer) {
        let snapshot = buildFleet()
        Self.syncLog.info("send fleet snapshot device=\(peer.deviceID, privacy: .public) sessions=\(snapshot.sessions.count) projects=\(snapshot.projects.count) sessionIDs=\(snapshot.sessions.map { $0.id.uuidString }, privacy: .public)")
        guard (try? peer.session.send(.fleet(snapshot))) != nil else { return }
        peer.lastFleet = snapshot
        peer.fleetRevision = 0
    }

    private func publishTranscript(to peer: Peer) async {
        // File reads suspend this actor. A watcher, timer, and adapter callback
        // can all arrive during that suspension; serialize their sends so a
        // phone never receives two different updates with the same revision.
        if peer.isPublishingTranscript {
            peer.transcriptPublishPending = true
            return
        }
        peer.isPublishingTranscript = true
        defer { peer.isPublishingTranscript = false }
        repeat {
            peer.transcriptPublishPending = false
            await publishTranscriptOnce(to: peer)
        } while peer.transcriptPublishPending && peers.values.contains(where: { $0 === peer })
    }

    private func publishTranscriptOnce(to peer: Peer) async {
        guard let sessionID = peer.subscribedSessionID,
              let session = store.sessions.first(where: { $0.id == sessionID }) else { return }
        let generation = peer.subscriptionGeneration
        let transcript: SessionTranscript
        if let adapter = adapters.adapter(for: session), session.agent == .openCode {
            transcript = adapter.transcript
        } else {
            guard var native = await transcripts.transcript(for: session, ifChangedSince: nil) else { return }
            if let adapter = adapters.adapter(for: session) {
                native.streamingText = adapter.transcript.streamingText
                native.retryAttempt = adapter.transcript.retryAttempt
                native.events += adapter.transcript.events.filter {
                    if case .turnFailed = $0.content {
                        true
                    } else {
                        false
                    }
                }
            }
            transcript = native
        }
        guard transcript != peer.lastTranscript, transcript != peer.unsendableTranscript else { return }
        guard peer.subscriptionGeneration == generation,
              peers.values.contains(where: { $0 === peer }) else { return }
        let revision = peer.transcriptRevision + 1
        let message: ServerMessage
        if let old = peer.lastTranscript,
           let delta = TranscriptDelta.make(from: old, to: transcript, baseRevision: peer.transcriptRevision)
        {
            message = .transcriptDelta(sessionID: sessionID, delta)
        } else {
            message = .transcriptSnapshot(sessionID: sessionID, revision: revision, transcript)
        }
        do {
            try peer.session.send(message)
        } catch TransportError.frameTooLarge {
            peer.unsendableTranscript = transcript
            var oversized = transcript
            oversized.events = []
            oversized.unavailableReason = "This transcript is too large to send in one update. Open it on the Mac."
            guard (try? peer.session.send(.transcriptSnapshot(sessionID: sessionID, revision: revision, oversized))) != nil else { return }
            peer.lastTranscript = oversized
            peer.transcriptRevision = revision
            return
        } catch { return }
        peer.lastTranscript = transcript
        peer.unsendableTranscript = nil
        peer.transcriptRevision = revision
    }

    // MARK: - Handy Speech to Text

    func checkHandyConnection() async {
        handyStatus = .checking
        let result: CompanionSpeechEvent
        if let handyCheckTask {
            // Startup, settings onAppear, and Check Again can all arrive in
            // the same run-loop turn. Share the in-flight handshake instead
            // of opening several sockets and letting a stale failure replace
            // a successful ready result.
            result = await handyCheckTask.value
        } else {
            let speech = localSpeech
            let task = Task { await speech.capabilities() }
            handyCheckTask = task
            result = await task.value
            handyCheckTask = nil
        }
        switch result {
        case let .capabilities(status, models):
            if status == "ready" {
                handyStatus = .connected(model: models.first)
            } else {
                handyStatus = .disconnected(reason: "Handy is \(status).")
            }
        case let .failed(_, _, message, _):
            handyStatus = .disconnected(reason: message)
        default:
            handyStatus = .disconnected(reason: "Handy is not reachable on this Mac.")
        }
    }

    func openHandyApp() {
        let handyID = "computer.handy.macos"
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: handyID) ?? URL(fileURLWithPath: "/Applications/Handy.app") as URL? {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    func buildFleet() -> FleetSnapshot {
        let snapshot = CompanionSnapshotBuilder.snapshot(
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
                    answerable: session.agent == .claudeCode ? bridge.pending(for: session.id) : adapters.pending(session) + bridge.pending(for: session.id),
                    suppressTerminalFallback: session.agent != .claudeCode && adapters.suppressesTerminalFallback(for: session)
                )
            }
        )
        if !store.sessions.isEmpty && snapshot.sessions.isEmpty {
            Self.syncLog.error("BUG fleet mapping dropped all sessions storeSessions=\(self.store.sessions.count) projects=\(snapshot.projects.count)")
        }
        return snapshot
    }
}
