import Foundation
import Observation
import SessionKit

enum Route: Hashable {
    case fleet(MacHost.ID)
    case session(CompanionSession.ID)
    /// A session's working diff, or one commit's when `commitHash` is set.
    case diff(CompanionSession.ID, commitHash: String?, focusPath: String?)
    case commits(CompanionSession.ID)
    case file(CompanionSession.ID, path: String)
}

/// The single object views talk to. Owns navigation and phone-local memory,
/// gates every action on the Mac being reachable, and forwards the rest to
/// whichever `CompanionDataSource` it was built with.
@Observable
@MainActor
final class CompanionStore {
    let data: any CompanionDataSource

    var path: [Route] = [] {
        didSet { rememberLastMac() }
    }

    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let lastMac = "companion.lastMacID"
        static func choice(_ project: UUID?) -> String { "companion.choice.\(project?.uuidString ?? "general")" }
    }

    init(data: any CompanionDataSource, defaults: UserDefaults = .standard) {
        self.data = data
        self.defaults = defaults
    }

    /// Launch lands on the last Mac viewed, with the Macs screen one Back away.
    func restoreLastMac() {
        guard let id = defaults.string(forKey: Key.lastMac), mac(id) != nil else { return }
        path = [.fleet(id)]
    }

    private func rememberLastMac() {
        if case .fleet(let id)? = path.first {
            defaults.set(id, forKey: Key.lastMac)
        }
    }

    // MARK: - Reads

    var macs: [MacHost] { data.macs }

    func mac(_ id: MacHost.ID) -> MacHost? {
        data.macs.first { $0.id == id }
    }

    func mac(forSession id: CompanionSession.ID) -> MacHost? {
        data.macID(for: id).flatMap(mac)
    }

    func sessions(on macID: MacHost.ID) -> [CompanionSession] { data.sessions(on: macID) }
    func projects(on macID: MacHost.ID) -> [ProjectSummary] { data.projects(on: macID) }
    func catalog(on macID: MacHost.ID) -> AgentCatalog { data.catalog(on: macID) }
    func session(_ id: CompanionSession.ID) -> CompanionSession? { data.session(id) }
    func transcript(for id: CompanionSession.ID) -> SessionTranscript { data.transcript(for: id) }
    func pendingInteractions(for id: CompanionSession.ID) -> [PendingInteraction] { data.pendingInteractions(for: id) }
    func diff(for id: CompanionSession.ID) -> [FileDiff] { data.diff(for: id) }
    func commits(for id: CompanionSession.ID) -> [CommitSummary] { data.commits(for: id) }
    func fileContents(at path: String, in id: CompanionSession.ID) -> String? { data.fileContents(at: path, in: id) }

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

    // MARK: - Intents

    func answer(_ interaction: PendingInteraction.ID, in session: CompanionSession.ID, with answer: InteractionAnswer) async -> AnswerOutcome? {
        guard isActionable(sessionID: session) else { return nil }
        return await data.answer(interaction, in: session, with: answer)
    }

    func sendPrompt(_ text: String, to session: CompanionSession.ID) async {
        guard isActionable(sessionID: session) else { return }
        await data.sendPrompt(text, to: session)
    }

    func stop(_ session: CompanionSession.ID) async {
        guard isActionable(sessionID: session) else { return }
        await data.stop(session)
    }

    func createSession(_ request: NewSessionRequest, on macID: MacHost.ID) async -> CompanionSession.ID? {
        guard isActionable(macID: macID) else { return nil }
        rememberChoice(request)
        return await data.createSession(request, on: macID)
    }

    func handoff(_ session: CompanionSession.ID, _ request: HandoffRequest) async {
        guard isActionable(sessionID: session) else { return }
        await data.handoff(session, request)
    }

    func restart(_ session: CompanionSession.ID) async {
        guard isActionable(sessionID: session) else { return }
        await data.restart(session)
    }

    func delete(_ session: CompanionSession.ID, removeWorktree: Bool) async {
        guard isActionable(sessionID: session) else { return }
        path.removeAll { route in
            switch route {
            case .session(let id), .diff(let id, _, _), .commits(let id), .file(let id, _): id == session
            case .fleet: false
            }
        }
        await data.delete(session, removeWorktree: removeWorktree)
    }

    func acknowledgeReview(_ session: CompanionSession.ID) {
        data.acknowledgeReview(session)
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
