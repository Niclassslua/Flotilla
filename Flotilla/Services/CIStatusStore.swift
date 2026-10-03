import Foundation
import Observation
import SessionKit
import GitKit

/// What GitHub CI says about each session's branch, kept current by polling
/// `gh`.
///
/// Unlike `DiffStatStore`, which only polls what is on screen, this watches
/// every session with a worktree branch: a failure is worth knowing about
/// precisely when the session is *not* in view, and the Dock badge and menu
/// bar count it from here.
@Observable @MainActor
final class CIStatusStore {
    private(set) var statuses: [UUID: CIStatus] = [:]

    /// Called once per session when its CI goes from not-failing to failing,
    /// with the first failing check. Never for a failure already present when
    /// Flotilla first looked — that is old news, not an event.
    @ObservationIgnored var onFailure: (@MainActor (Session, CICheck) -> Void)?

    @ObservationIgnored private let ghService: (any GhServiceProtocol)?
    /// Set by the owner once it exists; a closure so the store always polls
    /// the current fleet, including sessions created after it started.
    @ObservationIgnored var sessions: @MainActor () -> [Session]
    @ObservationIgnored private var nextPoll: [UUID: Date] = [:]
    @ObservationIgnored private var inFlight: Set<UUID> = []
    @ObservationIgnored private var loop: Task<Void, Never>?

    /// Fast while something is running so a red result shows up within half a
    /// minute; slow once settled, when only a new push can change it.
    static let pendingInterval: TimeInterval = 30
    static let settledInterval: TimeInterval = 180
    /// After `gh` fails (not a GitHub repo, signed out, offline), wait before
    /// asking again rather than spawning a doomed process every tick.
    static let errorBackoff: TimeInterval = 600

    init(ghService: (any GhServiceProtocol)?, sessions: @escaping @MainActor () -> [Session] = { [] }) {
        self.ghService = ghService
        self.sessions = sessions
    }

    func status(for sessionID: UUID) -> CIStatus? {
        statuses[sessionID]
    }

    var failingSessionIDs: Set<UUID> {
        Set(statuses.compactMap { $0.value.state == .failing ? $0.key : nil })
    }

    func start() {
        guard ghService != nil, loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollDueSessions()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Re-reads one session now — after the user sends a failure to its
    /// agent, or opens the Checks tab.
    func refresh(sessionID: UUID) async {
        guard let session = sessions().first(where: { $0.id == sessionID }) else { return }
        await poll(session)
    }

    /// The demo fleet has no GitHub remote; it shows CI by seeding it.
    func seed(_ seeded: [UUID: CIStatus]) {
        statuses.merge(seeded) { _, new in new }
    }

    private func pollDueSessions() async {
        let current = sessions()
        let liveIDs = Set(current.map(\.id))
        for id in statuses.keys where !liveIDs.contains(id) {
            statuses[id] = nil
            nextPoll[id] = nil
        }

        let now = Date()
        for session in current where Self.branch(of: session) != nil {
            guard !inFlight.contains(session.id), (nextPoll[session.id] ?? .distantPast) <= now else { continue }
            if statuses[session.id]?.isSettledForever == true { continue }
            await poll(session)
        }
    }

    private func poll(_ session: Session) async {
        guard let ghService, let branch = Self.branch(of: session), let repo = session.worktree?.worktreePath else { return }
        inFlight.insert(session.id)
        defer { inFlight.remove(session.id) }

        let previous = statuses[session.id]
        do {
            let status = try await ghService.ciStatus(forBranch: branch, at: repo)
            statuses[session.id] = status
            let interval = status?.state == .pending ? Self.pendingInterval : Self.settledInterval
            nextPoll[session.id] = Date().addingTimeInterval(interval)
            if let status, Self.isNewFailure(previous: previous, current: status), let check = status.failingChecks.first {
                onFailure?(session, check)
            }
        } catch {
            nextPoll[session.id] = Date().addingTimeInterval(Self.errorBackoff)
        }
    }

    /// Only an observed transition counts. The first reading has nothing to
    /// compare against, so a branch that was already red at launch stays
    /// silent.
    static func isNewFailure(previous: CIStatus?, current: CIStatus) -> Bool {
        guard let previous, current.state == .failing else { return false }
        return previous.state != .failing
    }

    /// Only worktree sessions own a branch. A session in the main checkout is
    /// on whatever the user has checked out there, usually the default
    /// branch, whose CI is not this session's result.
    static func branch(of session: Session) -> String? {
        guard let branch = session.worktree?.branchName, !branch.isEmpty else { return nil }
        return branch
    }
}
