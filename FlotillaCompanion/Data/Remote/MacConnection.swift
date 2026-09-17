import CompanionKit
import Foundation
import Observation
import os

/// The live link to one paired Mac, plus everything received from it.
@MainActor
@Observable
final class MacConnection {
    private static let performance = Logger(subsystem: "com.niclassslua.flotilla", category: "CompanionPerformance")
    private static let syncLog = Logger(subsystem: "com.niclassslua.flotilla", category: "CompanionSync")
    private(set) var record: PairedMacRecord
    private(set) var state: MacConnectionState = .unreachable
    private(set) var fleet: FleetSnapshot?
    private(set) var transcripts: [UUID: SessionTranscript] = [:]
    /// When the phone received the current `fleet`/each transcript — never
    /// when the Mac produced it — so a cached view can say honestly "as of
    /// <time>" instead of presenting stale content as live.
    private(set) var fleetReceivedAt: Date?
    private(set) var transcriptsReceivedAt: [UUID: Date] = [:]
    private(set) var diffs: [String: Remote<[FileDiff]>] = [:]
    private(set) var commits: [UUID: Remote<[CommitSummary]>] = [:]
    private(set) var files: [String: Remote<String?>] = [:]
    /// The last connection attempt, per address, for the diagnostics screen.
    private(set) var lastAttempts: [ConnectTarget: AttemptStatus] = [:]
    private(set) var lastDiagnosis: ConnectionDiagnosis?

    private(set) var queuedPrompts: [UUID: [QueuedPrompt]] = [:]
    private(set) var acknowledgedReviews: Set<UUID> = []
    /// Cards that just disappeared, shown briefly with how they ended.
    private(set) var resolvedCards: [UUID: [PendingInteraction]] = [:]

    @ObservationIgnored private var session: ClientSideSession?
    @ObservationIgnored private var nextRequestID: UInt64 = 1
    @ObservationIgnored private var waiting: [UInt64: CheckedContinuation<CompanionResponse, Error>] = [:]
    @ObservationIgnored private var focusedSessionID: UUID?
    @ObservationIgnored private var focusStartedAt: Date?
    @ObservationIgnored private var transcriptRevisions: [UUID: UInt64] = [:]
    @ObservationIgnored private var cacheRevision: UInt64 = 0
    @ObservationIgnored private var fleetRevision: UInt64?
    @ObservationIgnored private var diffLoads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var commitLoads: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var fileLoads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var retryAttempt = 0
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var answeredHere: Set<UUID> = []
    @ObservationIgnored private var initialFleetWaiter: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var initialFleetTimeoutTask: Task<Void, Never>?

    @ObservationIgnored private let identityStore: any DeviceIdentityStoring
    @ObservationIgnored private let browser: LANBrowser?
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored var onRecordChange: (PairedMacRecord) -> Void = { _ in }
    @ObservationIgnored var onCacheChange: (PairedMacStore.Cache, UInt64) -> Void = { _, _ in }
    @ObservationIgnored var onCacheFlush: (PairedMacStore.Cache, UInt64) -> Void = { _, _ in }
    @ObservationIgnored var onCacheDiscard: () async -> Void = {}
    @ObservationIgnored var onFleetChange: () -> Void = {}
    @ObservationIgnored var onAttention: (SessionAttentionEvent) -> Void = { _ in }

    static let requestTimeout: Duration = .seconds(45)
    static let retryDelays: [Double] = [1, 2, 5, 10, 20, 30]

    init(
        record: PairedMacRecord,
        cache: PairedMacStore.Cache?,
        identityStore: any DeviceIdentityStoring,
        browser: LANBrowser?,
        deviceName: String
    ) {
        self.record = record
        fleet = cache?.fleet
        transcripts = cache?.transcripts ?? [:]
        fleetReceivedAt = cache?.fleetReceivedAt
        transcriptsReceivedAt = cache?.transcriptsReceivedAt ?? [:]
        self.identityStore = identityStore
        self.browser = browser
        self.deviceName = deviceName
        if let reason = record.repairReason.flatMap(Self.repairReason(from:)) {
            state = .needsRepairing(reason)
        }
    }

    var isConnected: Bool {
        if case .connected = state {
            return true
        }
        return false
    }

    // MARK: - Lifecycle

    func setActive(_ active: Bool) {
        isActive = active
        if active {
            expireCachedTranscripts()
            if case .needsRepairing = state {
                return
            }
            if !isConnected {
                connect()
            }
        } else {
            onCacheFlush(currentCache(), cacheRevision)
            connectTask?.cancel()
            disconnect()
        }
    }

    /// Tries every known address now, resetting the backoff.
    func connect() {
        if case .needsRepairing = state {
            return
        }
        guard connectTask == nil, !isConnected else { return }
        retryAttempt = 0
        scheduleConnect(after: 0)
    }

    /// The user asked for it explicitly: cancels a pending backoff delay
    /// (`connect()` alone is a no-op while one is scheduled) and attempts
    /// right away. Identity mismatch and revocation still require re-pairing.
    func reconnectNow() {
        if case .needsRepairing = state {
            return
        }
        guard !isConnected else { return }
        connectTask?.cancel()
        connectTask = nil
        retryAttempt = 0
        scheduleConnect(after: 0)
    }

    private func scheduleConnect(after delay: Double) {
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self else { return }
            await self.attemptConnection()
            self.connectTask = nil
        }
    }

    private func attemptConnection() async {
        guard isActive else { return }
        state = .connecting
        let targets = connectTargets()
        let log = AttemptLog()
        do {
            let identity = try identityStore.loadOrCreate()
            let macID = record.macID
            let name = deviceName
            let result = try await CompanionClient.connect(
                to: targets,
                hello: {
                    try Handshake.makeClientHello(mode: .resume, macID: macID, deviceID: identity.deviceID, deviceName: name, identity: identity.identity, pairingSecret: nil)
                },
                pinnedMacKey: record.macKey,
                onAttempt: { target, status in log.record(target, status) }
            )
            guard !Task.isCancelled, isActive else {
                result.session.close()
                return
            }
            lastAttempts = log.snapshot
            lastDiagnosis = nil
            adopt(result.session, target: result.target, macName: result.serverHello.macName)
        } catch {
            lastAttempts = log.snapshot
            handleConnectFailure(error, offered: Set(targets.map(\.path)))
        }
    }

    private func handleConnectFailure(_ error: Error, offered: Set<NetworkPath>) {
        lastDiagnosis = ConnectionDiagnosis.diagnose(
            error: error,
            attempts: lastAttempts,
            offeredPaths: offered,
            phoneHasTailnet: NetworkInterfaces.hasTailnetAddress,
            localNetworkDenied: browser?.permission == .denied
        )
        switch error {
        case ConnectError.handshake(.rejected(.revoked)):
            markNeedsRepairing(.revoked)
        case ConnectError.handshake(.rejected(.unknownDevice)):
            markNeedsRepairing(.unknownDevice)
        case ConnectError.handshake(.macIdentityMismatch):
            markNeedsRepairing(.identityChanged)
        case ConnectError.handshake(.rejected(.versionUnsupported)), ConnectError.handshake(.versionMismatch):
            markNeedsRepairing(.versionMismatch)
        default:
            state = .unreachable
            guard isActive else { return }
            let delay = Self.retryDelays[min(retryAttempt, Self.retryDelays.count - 1)]
            retryAttempt += 1
            scheduleConnect(after: delay)
        }
    }

    private func markNeedsRepairing(_ reason: MacConnectionState.RepairReason) {
        state = .needsRepairing(reason)
        record.repairReason = String(describing: reason)
        onRecordChange(record)
    }

    private static func repairReason(from string: String) -> MacConnectionState.RepairReason? {
        switch string {
        case "revoked": .revoked
        case "unknownDevice": .unknownDevice
        case "identityChanged": .identityChanged
        case "versionMismatch": .versionMismatch
        default: nil
        }
    }

    private func connectTargets() -> [ConnectTarget] {
        var targets: [ConnectTarget] = []
        if let discovered = browser?.endpoint(forMac: record.macID) {
            targets.append(ConnectTarget(path: .lan, label: "\(discovered.name) (Bonjour)", endpoint: discovered.endpoint))
        }
        for candidate in record.candidates {
            if let target = ConnectTarget(candidate), !targets.contains(target) {
                targets.append(target)
            }
        }
        return targets
    }

    /// Takes over an authenticated session — from `attemptConnection`, or
    /// the one pairing just opened.
    func adopt(_ newSession: ClientSideSession, target: ConnectTarget, macName: String) {
        disconnect()
        session = newSession
        transcriptRevisions.removeAll()
        fleetRevision = nil
        retryAttempt = 0
        state = .connected(path: target.path, address: target.label)
        record.name = macName
        record.lastSeen = .now
        record.repairReason = nil
        if let candidate = record.candidates.first(where: { ConnectTarget($0) == target }) {
            record.lastConnected = candidate
        }
        onRecordChange(record)

        newSession.onClose { [weak self] _ in
            Task { @MainActor in self?.sessionClosed(newSession) }
        }
        receiveTask = Task { [weak self] in
            do {
                for try await message in newSession.messages {
                    self?.receive(message)
                }
            } catch {}
        }
        if let focusedSessionID {
            try? newSession.send(.subscribe(sessionID: focusedSessionID))
        }
    }

    /// Pairing is not complete until the Mac has approved the phone and sent
    /// its first fleet snapshot. This keeps the phone on the pairing screen
    /// while the Mac user makes that security decision.
    func waitForInitialFleet() async throws {
        if fleet != nil {
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            initialFleetWaiter = continuation
            initialFleetTimeoutTask?.cancel()
            initialFleetTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled, let self, let waiter = self.initialFleetWaiter else { return }
                self.initialFleetWaiter = nil
                waiter.resume(throwing: CompanionActionError(message: "The Mac did not confirm this iPhone in time."))
            }
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        let closing = session
        session = nil
        closing?.close()
        initialFleetTimeoutTask?.cancel()
        initialFleetTimeoutTask = nil
        if let waiter = initialFleetWaiter {
            initialFleetWaiter = nil
            waiter.resume(throwing: CompanionActionError.unreachable)
        }
        failWaiting(CompanionActionError.unreachable)
        if isConnected {
            state = .unreachable
        }
    }

    private func sessionClosed(_ closed: ClientSideSession) {
        guard closed === session else { return }
        session = nil
        receiveTask = nil
        failWaiting(CompanionActionError.unreachable)
        record.lastSeen = .now
        onRecordChange(record)
        if case .needsRepairing = state {
            return
        }
        state = .unreachable
        if isActive {
            scheduleConnect(after: Self.retryDelays[0])
        }
    }

    private func failWaiting(_ error: Error) {
        let pending = waiting
        waiting = [:]
        pending.values.forEach { $0.resume(throwing: error) }
    }

    // MARK: - Incoming

    private func receive(_ message: ServerMessage) {
        record.lastSeen = .now
        switch message {
        case let .fleet(snapshot):
            Self.syncLog.info("received fleet mac=\(self.record.macID, privacy: .public) sessions=\(snapshot.sessions.count) projects=\(snapshot.projects.count) sessionIDs=\(snapshot.sessions.map { $0.id.uuidString }, privacy: .public)")
            fleetRevision = 0
            applyFleet(snapshot)
        case let .fleetDelta(delta):
            guard let fleet, let fleetRevision,
                  let updated = delta.applying(to: fleet, revision: fleetRevision)
            else {
                Self.syncLog.error("rejected fleet delta mac=\(self.record.macID, privacy: .public) base=\(delta.baseRevision) revision=\(delta.revision) localRevision=\(self.fleetRevision ?? 999_999) localSessions=\(self.fleet?.sessions.count ?? 0); requesting resync")
                try? session?.send(.resyncFleet)
                return
            }
            Self.syncLog.info("received fleet delta mac=\(self.record.macID, privacy: .public) base=\(delta.baseRevision) revision=\(delta.revision) ordered=\(delta.orderedIDs.count) changed=\(delta.changed.count) resultingSessions=\(updated.sessions.count) projects=\(updated.projects.count)")
            self.fleetRevision = delta.revision
            applyFleet(updated)
        case let .transcript(sessionID, transcript):
            transcripts[sessionID] = transcript
            transcriptsReceivedAt[sessionID] = .now
            pruneQueuedPrompts(sessionID)
            saveCache()
        case let .transcriptSnapshot(sessionID, revision, transcript):
            guard focusedSessionID == sessionID else { return }
            if let focusStartedAt {
                Self.performance.debug("first transcript \(Date().timeIntervalSince(focusStartedAt), format: .fixed(precision: 4))s events=\(transcript.events.count)")
                self.focusStartedAt = nil
            }
            transcriptRevisions[sessionID] = revision
            transcripts[sessionID] = transcript
            transcriptsReceivedAt[sessionID] = .now
            pruneQueuedPrompts(sessionID)
            saveCache()
        case let .transcriptDelta(sessionID, delta):
            guard focusedSessionID == sessionID else { return }
            guard let old = transcripts[sessionID], let revision = transcriptRevisions[sessionID],
                  let updated = delta.applying(to: old, revision: revision)
            else {
                try? session?.send(.resyncTranscript(sessionID: sessionID))
                return
            }
            transcriptRevisions[sessionID] = delta.revision
            transcripts[sessionID] = updated
            transcriptsReceivedAt[sessionID] = .now
            pruneQueuedPrompts(sessionID)
            saveCache()
        case let .response(id, response):
            waiting.removeValue(forKey: id)?.resume(returning: response)
        case .pong:
            break
        case let .addressUpdate(candidates):
            guard candidates != record.candidates else { return }
            record.candidates = candidates
            onRecordChange(record)
        case let .attention(event):
            onAttention(event)
        }
    }

    private func applyFleet(_ snapshot: FleetSnapshot) {
        let previousSessionIDs = Set(fleet?.sessions.map(\.id) ?? [])
        let incomingSessionIDs = Set(snapshot.sessions.map(\.id))
        if !previousSessionIDs.isEmpty, incomingSessionIDs.isEmpty {
            Self.syncLog.error("fleet update removed every session mac=\(self.record.macID, privacy: .public) previous=\(previousSessionIDs.count) projects=\(snapshot.projects.count)")
        }
        let previous = fleet?.pending ?? [:]
        for (sessionID, cards) in previous {
            let stillOpen = Set((snapshot.pending[sessionID] ?? []).map(\.id))
            let gone = cards.filter { !stillOpen.contains($0.id) && !answeredHere.contains($0.id) }
            guard !gone.isEmpty else { continue }
            showResolved(gone.map { card in
                var resolved = card
                resolved.resolution = .answeredOnMac(outcome: Self.macOutcome(for: card))
                return resolved
            }, in: sessionID)
        }
        fleet = snapshot
        initialFleetTimeoutTask?.cancel()
        initialFleetTimeoutTask = nil
        if let waiter = initialFleetWaiter {
            initialFleetWaiter = nil
            waiter.resume()
        }
        fleetReceivedAt = .now
        Self.syncLog.debug("applied fleet mac=\(self.record.macID, privacy: .public) sessions=\(snapshot.sessions.count) projects=\(snapshot.projects.count)")
        onFleetChange()
        if case .connected = state, snapshot.macName != record.name {
            record.name = snapshot.macName
            onRecordChange(record)
        }
        saveCache()
    }

    private static func macOutcome(for card: PendingInteraction) -> String {
        switch card.kind {
        case .permission, .needsTerminal: "Answered"
        case .question: "Answered"
        case .plan: "Handled"
        }
    }

    private func showResolved(_ cards: [PendingInteraction], in sessionID: UUID) {
        resolvedCards[sessionID, default: []].append(contentsOf: cards)
        let ids = Set(cards.map(\.id))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.resolvedCards[sessionID]?.removeAll { ids.contains($0.id) }
        }
    }

    private func saveCache() {
        cacheRevision += 1
        onCacheChange(currentCache(), cacheRevision)
    }

    private func currentCache() -> PairedMacStore.Cache {
        PairedMacStore.Cache(fleet: fleet, transcripts: transcripts, fleetReceivedAt: fleetReceivedAt, transcriptsReceivedAt: transcriptsReceivedAt)
    }

    /// Replace the persisted snapshot immediately. Its higher revision also
    /// invalidates any older debounced snapshot still waiting in the writer.
    func clearCachedTranscripts() {
        guard !transcripts.isEmpty || !transcriptsReceivedAt.isEmpty else { return }
        transcripts.removeAll()
        transcriptsReceivedAt.removeAll()
        transcriptRevisions.removeAll()
        cacheRevision += 1
        onCacheFlush(currentCache(), cacheRevision)
    }

    func expireCachedTranscripts(now: Date = .now) {
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let expired = Set(transcripts.keys).union(transcriptsReceivedAt.keys).filter { sessionID in
            guard transcripts[sessionID] != nil else { return true }
            guard let receivedAt = transcriptsReceivedAt[sessionID] else { return true }
            return receivedAt <= cutoff
        }
        guard !expired.isEmpty else { return }
        for sessionID in expired {
            transcripts.removeValue(forKey: sessionID)
            transcriptsReceivedAt.removeValue(forKey: sessionID)
            transcriptRevisions.removeValue(forKey: sessionID)
        }
        cacheRevision += 1
        onCacheFlush(currentCache(), cacheRevision)
    }

    // MARK: - Reads

    func pending(for sessionID: UUID) -> [PendingInteraction] {
        (resolvedCards[sessionID] ?? []) + (fleet?.pending[sessionID] ?? [])
    }

    func transcript(for sessionID: UUID) -> SessionTranscript {
        var transcript = transcripts[sessionID] ?? SessionTranscript()
        transcript.queuedPrompts = queuedPrompts[sessionID] ?? []
        return transcript
    }

    /// Drops queued prompts the Mac's transcript now contains.
    private func pruneQueuedPrompts(_ sessionID: UUID) {
        guard var queued = queuedPrompts[sessionID], !queued.isEmpty,
              let events = transcripts[sessionID]?.events else { return }
        let delivered = events.compactMap { event -> (String, Date)? in
            if case let .userMessage(text, timestamp) = event.content {
                return (text, timestamp)
            }
            return nil
        }
        queued.removeAll { prompt in
            delivered.contains { $0.0.trimmingCharacters(in: .whitespacesAndNewlines) == prompt.text && $0.1 >= prompt.sentAt.addingTimeInterval(-5) }
        }
        queuedPrompts[sessionID] = queued
    }

    // MARK: - Requests

    func focus(on sessionID: UUID?) {
        guard sessionID != focusedSessionID else { return }
        focusedSessionID = sessionID
        if let sessionID {
            focusStartedAt = .now
            transcriptRevisions[sessionID] = nil
            try? session?.send(.subscribe(sessionID: sessionID))
        } else {
            focusStartedAt = nil
            try? session?.send(.unsubscribe)
        }
    }

    func request(_ request: CompanionRequest) async throws -> CompanionResponse {
        guard let session else { throw CompanionActionError.unreachable }
        let id = nextRequestID
        nextRequestID += 1
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.requestTimeout)
            guard !Task.isCancelled else { return }
            self?.waiting.removeValue(forKey: id)?.resume(throwing: CompanionActionError(message: "The Mac didn't respond in time."))
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            do {
                try session.send(.request(id: id, request))
            } catch {
                waiting.removeValue(forKey: id)?.resume(throwing: CompanionActionError.unreachable)
            }
        }
    }

    /// Sends a request that answers with `.ok`, throwing its failure message.
    func perform(_ request: CompanionRequest) async throws {
        let response = try await self.request(request)
        if case let .failure(message) = response {
            throw CompanionActionError(message: message)
        }
    }

    func answer(_ interactionID: UUID, in sessionID: UUID, with answer: InteractionAnswer) async throws -> AnswerOutcome {
        answeredHere.insert(interactionID)
        let response = try await request(.answer(sessionID: sessionID, interactionID: interactionID, answer: answer))
        switch response {
        case let .answer(outcome):
            if outcome == .alreadyAnswered, var card = fleet?.pending[sessionID]?.first(where: { $0.id == interactionID }) {
                card.resolution = .alreadyAnswered
                showResolved([card], in: sessionID)
            }
            return outcome
        case let .failure(message):
            answeredHere.remove(interactionID)
            throw CompanionActionError(message: message)
        default:
            return .accepted
        }
    }

    func sendPrompt(_ text: String, to sessionID: UUID) async throws {
        let isBusy = fleet?.sessions.first { $0.id == sessionID }?.status == .working
        let prompt = QueuedPrompt(text: text, sentAt: .now)
        if isBusy {
            queuedPrompts[sessionID, default: []].append(prompt)
        }
        do {
            try await perform(.sendPrompt(sessionID: sessionID, text: text))
        } catch {
            queuedPrompts[sessionID]?.removeAll { $0.id == prompt.id }
            throw error
        }
    }

    func acknowledgeReview(_ sessionID: UUID) {
        acknowledgedReviews.insert(sessionID)
    }

    func loadDiff(for sessionID: UUID, commitHash: String?) async {
        let key = "\(sessionID)|\(commitHash ?? "")"
        if let pending = diffLoads[key] {
            await pending.value; return
        }
        let task = Task { await fetchDiff(for: sessionID, commitHash: commitHash, key: key) }
        diffLoads[key] = task
        await task.value
        diffLoads[key] = nil
    }

    private func fetchDiff(for sessionID: UUID, commitHash: String?, key: String) async {
        if diffs[key]?.value == nil {
            diffs[key] = .loading
        }
        do {
            switch try await request(.diff(sessionID: sessionID, commitHash: commitHash)) {
            case let .diff(files): diffs[key] = .loaded(files)
            case let .failure(message): diffs[key] = .failed(message)
            default: diffs[key] = .failed("Unexpected response.")
            }
        } catch {
            if diffs[key]?.value == nil {
                diffs[key] = .failed(error.localizedDescription)
            }
        }
    }

    func diff(for sessionID: UUID, commitHash: String?) -> Remote<[FileDiff]> {
        diffs["\(sessionID)|\(commitHash ?? "")"] ?? .loading
    }

    func loadCommits(for sessionID: UUID) async {
        if let pending = commitLoads[sessionID] {
            await pending.value; return
        }
        let task = Task { await fetchCommits(for: sessionID) }
        commitLoads[sessionID] = task
        await task.value
        commitLoads[sessionID] = nil
    }

    private func fetchCommits(for sessionID: UUID) async {
        if commits[sessionID]?.value == nil {
            commits[sessionID] = .loading
        }
        do {
            switch try await request(.commits(sessionID: sessionID)) {
            case let .commits(list): commits[sessionID] = .loaded(list)
            case let .failure(message): commits[sessionID] = .failed(message)
            default: commits[sessionID] = .failed("Unexpected response.")
            }
        } catch {
            if commits[sessionID]?.value == nil {
                commits[sessionID] = .failed(error.localizedDescription)
            }
        }
    }

    func loadFile(at path: String, in sessionID: UUID) async {
        let key = "\(sessionID)|\(path)"
        if let pending = fileLoads[key] {
            await pending.value; return
        }
        let task = Task { await fetchFile(at: path, in: sessionID, key: key) }
        fileLoads[key] = task
        await task.value
        fileLoads[key] = nil
    }

    private func fetchFile(at path: String, in sessionID: UUID, key: String) async {
        if files[key]?.value == nil {
            files[key] = .loading
        }
        do {
            var offset = 0
            var result = ""
            while true {
                switch try await request(.filePage(sessionID: sessionID, path: path, offset: offset, maxBytes: 192 * 1024)) {
                case let .filePage(contents, nextOffset, isComplete):
                    result += contents ?? ""
                    guard !isComplete, let nextOffset, nextOffset > offset else {
                        files[key] = .loaded(result)
                        return
                    }
                    offset = nextOffset
                case let .file(contents):
                    files[key] = .loaded(contents)
                    return
                case let .failure(message): files[key] = .failed(message); return
                default: files[key] = .failed("Unexpected response."); return
                }
            }
        } catch {
            if files[key]?.value == nil {
                files[key] = .failed(error.localizedDescription)
            }
        }
    }

    func fileContents(at path: String, in sessionID: UUID) -> Remote<String?> {
        files["\(sessionID)|\(path)"] ?? .loading
    }
}

/// Collects attempt statuses from the client's background callbacks.
final class AttemptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ConnectTarget: AttemptStatus] = [:]

    func record(_ target: ConnectTarget, _ status: AttemptStatus) {
        lock.withLock {
            // Keep the informative outcome; a late "abandoned" shouldn't hide
            // an earlier failure reason.
            if case .abandoned = status, case .failed? = entries[target] {
                return
            }
            entries[target] = status
        }
    }

    var snapshot: [ConnectTarget: AttemptStatus] {
        lock.withLock { entries }
    }
}
