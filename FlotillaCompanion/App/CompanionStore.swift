import Foundation
import Observation
import SessionKit
import CompanionKit

enum Route: Hashable {
    case fleet(MacHost.ID)
    case session(CompanionSession.ID)
    /// A session's working diff, or one commit's when `commitHash` is set.
    case diff(CompanionSession.ID, commitHash: String?, focusPath: String?)
    case commits(CompanionSession.ID)
    case file(CompanionSession.ID, path: String)
}

/// The single object views talk to. Owns navigation and phone-local memory,
/// gates every action on the Mac being reachable, surfaces failures, and
/// forwards the rest to whichever `CompanionDataSource` it was built with.
@Observable
@MainActor
final class CompanionStore {
    let data: any CompanionDataSource

    var path: [Route] = [] {
        didSet { rememberLastMac() }
    }

    /// The last intent that failed, shown as an alert.
    var actionError: CompanionActionError?

    /// A pairing link opened from outside the app (Camera, Safari), waiting
    /// for the pairing sheet to pick it up.
    var incomingPairingLink: String?

    /// The last Mac whose fleet was opened. Launch returns to it, and the
    /// fleet Live Activity follows it.
    private(set) var lastMacID: MacHost.ID?

    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let lastMac = "companion.lastMacID"
        static func choice(_ project: UUID?) -> String { "companion.choice.\(project?.uuidString ?? "general")" }
        static func promptDraft(_ macID: MacHost.ID, _ sessionID: CompanionSession.ID) -> String {
            "companion.draft.prompt.\(macID).\(sessionID.uuidString)"
        }
        static func planRevisionDraft(_ macID: MacHost.ID, _ sessionID: CompanionSession.ID) -> String {
            "companion.draft.planRevision.\(macID).\(sessionID.uuidString)"
        }
        static let draftPromptPrefix = "companion.draft.prompt."
        static let draftPlanRevisionPrefix = "companion.draft.planRevision."
        static func collapsedProjects(_ macID: MacHost.ID) -> String { "companion.fleet.collapsedProjects.\(macID)" }
    }

    init(data: any CompanionDataSource, defaults: UserDefaults = .standard) {
        self.data = data
        self.defaults = defaults
        lastMacID = defaults.string(forKey: Key.lastMac)
    }

    /// Launch lands on the last Mac viewed, with the Macs screen one Back away.
    func restoreLastMac() {
        guard let id = lastMacID, mac(id) != nil else { return }
        path = [.fleet(id)]
    }

    private func rememberLastMac() {
        if case .fleet(let id)? = path.first, id != lastMacID {
            lastMacID = id
            defaults.set(id, forKey: Key.lastMac)
        }
        let focused = path.reversed().lazy.compactMap { route -> CompanionSession.ID? in
            if case .session(let id) = route { return id }
            return nil
        }.first
        data.focus(on: focused)
    }

    // MARK: - Reads

    var macs: [MacHost] { data.macs }
    var supportsPairing: Bool { data.supportsPairing }

    func mac(_ id: MacHost.ID) -> MacHost? {
        data.macs.first { $0.id == id }
    }

    func mac(forSession id: CompanionSession.ID) -> MacHost? {
        data.macID(for: id).flatMap(mac)
    }

    func sessions(on macID: MacHost.ID) -> [CompanionSession] {
        observeDataChanges()
        return data.sessions(on: macID)
    }

    func projects(on macID: MacHost.ID) -> [ProjectSummary] {
        observeDataChanges()
        return data.projects(on: macID)
    }

    func catalog(on macID: MacHost.ID) -> AgentCatalog {
        observeDataChanges()
        return data.catalog(on: macID)
    }
    func session(_ id: CompanionSession.ID) -> CompanionSession? { data.session(id) }
    func transcript(for id: CompanionSession.ID) -> SessionTranscript { data.transcript(for: id) }
    func pendingInteractions(for id: CompanionSession.ID) -> [PendingInteraction] { data.pendingInteractions(for: id) }
    func fleetReceivedAt(_ macID: MacHost.ID) -> Date? { data.fleetReceivedAt(macID) }
    func transcriptReceivedAt(_ id: CompanionSession.ID) -> Date? { data.transcriptReceivedAt(id) }
    func diff(for id: CompanionSession.ID, commitHash: String?) -> Remote<[FileDiff]> { data.diff(for: id, commitHash: commitHash) }
    func commits(for id: CompanionSession.ID) -> Remote<[CommitSummary]> { data.commits(for: id) }
    func fileContents(at path: String, in id: CompanionSession.ID) -> Remote<String?> { data.fileContents(at: path, in: id) }

    /// Reads the forwarding token so views that consume the data source
    /// through this store are invalidated when a child MacConnection receives
    /// a new fleet snapshot.
    private func observeDataChanges() {
        _ = data.observationRevision
    }

    func loadDiff(for id: CompanionSession.ID, commitHash: String?) async { await data.loadDiff(for: id, commitHash: commitHash) }
    func loadCommits(for id: CompanionSession.ID) async { await data.loadCommits(for: id) }
    func loadFile(at path: String, in id: CompanionSession.ID) async { await data.loadFile(at: path, in: id) }

    func projectName(_ id: UUID?, on macID: MacHost.ID) -> String {
        guard let id else { return "General" }
        return projects(on: macID).first { $0.id == id }?.name ?? "General"
    }

    /// Offline, everything is read-only: no answers, prompts, swipes, or creation.
    func isActionable(macID: MacHost.ID) -> Bool {
        mac(macID)?.isReachable ?? false
    }

    func isActionable(sessionID: CompanionSession.ID) -> Bool {
        mac(forSession: sessionID)?.isReachable ?? false
    }

    func isSpeechAvailable(for sessionID: CompanionSession.ID) -> Bool {
        observeDataChanges()
        guard let macID = data.macID(for: sessionID) else { return false }
        return data.isSpeechAvailable(on: macID)
    }

    func isSpeechAvailable(for macID: MacHost.ID) -> Bool {
        observeDataChanges()
        return data.isSpeechAvailable(on: macID)
    }

    var isAnyMacSpeechAvailable: Bool {
        observeDataChanges()
        return data.macs.contains { data.isSpeechAvailable(on: $0.id) }
    }

    func setActive(_ isActive: Bool) {
        data.setActive(isActive)
    }

    var disconnectsWhenInactive: Bool { data.disconnectsWhenInactive }

    // MARK: - Intents

    /// Runs an intent, turning a thrown error into the alert.
    private func perform<T>(_ work: () async throws -> T) async -> T? {
        do {
            return try await work()
        } catch let error as CompanionActionError {
            actionError = error
        } catch {
            actionError = CompanionActionError(message: error.localizedDescription)
        }
        return nil
    }

    func answer(_ interaction: PendingInteraction.ID, in session: CompanionSession.ID, with answer: InteractionAnswer) async -> AnswerOutcome? {
        guard isActionable(sessionID: session) else { return nil }
        return await perform { try await data.answer(interaction, in: session, with: answer) }
    }

    @discardableResult
    func sendPrompt(_ text: String, to session: CompanionSession.ID) async -> Bool {
        guard isActionable(sessionID: session) else { return false }
        return await perform { try await data.sendPrompt(text, to: session) } != nil
    }

    func stop(_ session: CompanionSession.ID) async {
        guard isActionable(sessionID: session) else { return }
        await perform { try await data.stop(session) }
    }

    func createSession(_ request: NewSessionRequest, on macID: MacHost.ID) async -> CompanionSession.ID? {
        guard isActionable(macID: macID) else { return nil }
        rememberChoice(request)
        return await perform { try await data.createSession(request, on: macID) }
    }

    func handoff(_ session: CompanionSession.ID, _ request: HandoffRequest) async -> Bool {
        guard isActionable(sessionID: session) else { return false }
        return await perform { try await data.handoff(session, request) } != nil
    }

    func restart(_ session: CompanionSession.ID) async {
        guard isActionable(sessionID: session) else { return }
        await perform { try await data.restart(session) }
    }

    func delete(_ session: CompanionSession.ID, removeWorktree: Bool) async {
        guard isActionable(sessionID: session) else { return }
        let macID = data.macID(for: session)
        let succeeded = await perform { try await data.delete(session, removeWorktree: removeWorktree) } != nil
        guard succeeded else { return }
        if let macID {
            defaults.removeObject(forKey: Key.promptDraft(macID, session))
            defaults.removeObject(forKey: Key.planRevisionDraft(macID, session))
        }
        path.removeAll { route in
            switch route {
            case .session(let id), .diff(let id, _, _), .commits(let id), .file(let id, _): id == session
            case .fleet: false
            }
        }
    }

    func acknowledgeReview(_ session: CompanionSession.ID) {
        data.acknowledgeReview(session)
    }

    // MARK: - Macs

    func pair(with payload: PairingPayload, progress: @escaping @MainActor (ConnectTarget, AttemptStatus) -> Void) async throws -> MacHost.ID {
        try await data.pair(with: payload, progress: progress)
    }

    func removeMac(_ macID: MacHost.ID) {
        // Everything on the stack below a Mac's fleet belongs to that Mac.
        if case .fleet(macID)? = path.first { path = [] }
        purgeDrafts(forMac: macID)
        data.removeMac(macID)
    }

    private func purgeDrafts(forMac macID: MacHost.ID) {
        let promptPrefix = Key.draftPromptPrefix + macID + "."
        let planPrefix = Key.draftPlanRevisionPrefix + macID + "."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(promptPrefix) || key.hasPrefix(planPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    func reconnect(_ macID: MacHost.ID) {
        data.reconnect(macID)
    }

    func clearCachedTranscripts(on macID: MacHost.ID) {
        data.clearCachedTranscripts(on: macID)
    }

    func clearAllCachedTranscripts() {
        data.clearAllCachedTranscripts()
    }

    // MARK: - Drafts (per Mac + session, phone-local; survive navigation and relaunch)

    func promptDraft(for sessionID: CompanionSession.ID) -> String {
        guard let macID = data.macID(for: sessionID) else { return "" }
        return defaults.string(forKey: Key.promptDraft(macID, sessionID)) ?? ""
    }

    func savePromptDraft(_ text: String, for sessionID: CompanionSession.ID) {
        guard let macID = data.macID(for: sessionID) else { return }
        let key = Key.promptDraft(macID, sessionID)
        if text.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(text, forKey: key) }
    }

    func planRevisionDraft(for sessionID: CompanionSession.ID) -> String {
        guard let macID = data.macID(for: sessionID) else { return "" }
        return defaults.string(forKey: Key.planRevisionDraft(macID, sessionID)) ?? ""
    }

    func savePlanRevisionDraft(_ text: String, for sessionID: CompanionSession.ID) {
        guard let macID = data.macID(for: sessionID) else { return }
        let key = Key.planRevisionDraft(macID, sessionID)
        if text.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(text, forKey: key) }
    }

    // MARK: - Collapsed fleet projects (per Mac, phone-local; absent means expanded)

    func collapsedProjects(on macID: MacHost.ID) -> Set<String> {
        Set((defaults.array(forKey: Key.collapsedProjects(macID)) as? [String]) ?? [])
    }

    func setCollapsedProjects(_ names: Set<String>, on macID: MacHost.ID) {
        defaults.set(Array(names), forKey: Key.collapsedProjects(macID))
    }

    // MARK: - Remembered create-session choices (per project, like the Mac)

    struct AgentChoice: Codable {
        var agent: AgentKind
        var model: String
        var effort: AgentEffort?
    }

    func rememberedChoice(for project: UUID?) -> AgentChoice? {
        guard let data = defaults.data(forKey: Key.choice(project)) else { return nil }
        return try? JSONDecoder().decode(AgentChoice.self, from: data)
    }

    private func rememberChoice(_ request: NewSessionRequest) {
        let choice = AgentChoice(agent: request.agent, model: request.model, effort: request.effort)
        if let data = try? JSONEncoder().encode(choice) {
            defaults.set(data, forKey: Key.choice(request.projectID))
        }
    }

    // MARK: - Scenarios

    var supportsScenarios: Bool { data is MockCompanionDataSource }

    func run(_ scenario: Scenario) {
        guard let mock = data as? MockCompanionDataSource else { return }
        let focus = mock.run(scenario)
        path = [.fleet(focus.macID)] + (focus.sessionID.map { [.session($0)] } ?? [])
    }
}
