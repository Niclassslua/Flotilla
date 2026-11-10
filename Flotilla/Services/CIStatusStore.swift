import Foundation
import Observation
import SessionKit
import GitKit
import ProcessKit

/// Why the last `gh` call couldn't answer, phrased as what the user can do
/// about it. Kept apart from the result so an old answer can stay on screen,
/// labelled as old, while GitHub is out of reach.
enum CIPollProblem: Equatable {
    case signedOut
    case notGitHub
    case offline
    case other(String)

    init(error: Error) {
        guard case GitServiceError.ghCommandFailed(_, let stderr) = error else {
            self = error is CommandTimeoutError ? .offline : .other(error.localizedDescription)
            return
        }
        let text = stderr.lowercased()
        func mentions(_ phrases: String...) -> Bool { phrases.contains { text.contains($0) } }
        if mentions("gh auth login", "not logged in", "authentication") {
            self = .signedOut
        } else if mentions("none of the git remotes", "no git remotes", "not a git repository", "could not determine") {
            self = .notGitHub
        } else if mentions("error connecting", "tls handshake", "timeout", "no such host", "network is") {
            self = .offline
        } else {
            self = .other(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// The user asked the agent to fix this commit's failures.
struct CIFixAttempt: Equatable {
    let commitSHA: String?
    let sentAt: Date
}

/// Everything the UI needs to say about one session's CI.
struct CISnapshot: Equatable {
    var status: CIStatus?
    var tip: CILocalTip?
    var problem: CIPollProblem?
    var lastUpdated: Date?
    /// Set only while the fix is still plausibly under way.
    var fix: CIFixAttempt?
    var isDismissed = false
    var hasLoaded = false
    var isAwaitingCI = false
    /// CI is being held back until the session commits something.
    var isWaitingForFirstCommit = false

    var verdict: CIVerdict { CIVerdict(status: status, tip: tip) }

    /// The checks shown describe a commit other than the one in the worktree.
    var isForOlderCommit: Bool {
        guard let commit = status?.commitSHA, let tip, status?.isActionable == true else { return false }
        return commit != tip.sha
    }
}

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
    private var tips: [UUID: CILocalTip] = [:]
    private var problems: [UUID: CIPollProblem] = [:]
    private var lastUpdated: [UUID: Date] = [:]
    private var fixes: [UUID: CIFixAttempt] = [:]
    /// Sessions with at least one answered poll: the baseline that lets a
    /// later failure count as news.
    private var observed: Set<UUID> = []
    private var awaitingCIUntil: [UUID: Date] = [:]
    /// Session → the commit whose failure the user dismissed.
    private var dismissed: [String: String]

    /// Called once per session when a commit's CI newly blocks it, with the
    /// first blocking check. Never for a failure already present when
    /// Flotilla first looked — that is old news, not an event.
    @ObservationIgnored var onFailure: (@MainActor (Session, CICheck) -> Void)?
    /// Types a prompt into a session's agent. Set by the owner.
    @ObservationIgnored var deliver: (@MainActor (String, UUID) async throws -> Void)?
    /// The user's choice to see CI from before a session's first commit.
    @ObservationIgnored var showsCIBeforeSessionCommits: @MainActor () -> Bool = { false }

    @ObservationIgnored private let ghService: (any GhServiceProtocol)?
    @ObservationIgnored private let defaults: UserDefaults
    /// Set by the owner once it exists; a closure so the store always polls
    /// the current fleet, including sessions created after it started.
    @ObservationIgnored var sessions: @MainActor () -> [Session]
    @ObservationIgnored private var nextPoll: [UUID: Date] = [:]
    @ObservationIgnored private var nextTipProbe: [UUID: Date] = [:]
    @ObservationIgnored private var inFlight: Set<UUID> = []
    @ObservationIgnored private var excerpts: [Int: String] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// The demo fleet's CI is fixed; its fake branches must never reach `gh`.
    @ObservationIgnored private var isSeeded = false

    /// Fast while something is running so a red result shows up within half a
    /// minute; slow once settled, when only a new push can change it.
    static let pendingInterval: TimeInterval = 30
    static let settledInterval: TimeInterval = 180
    /// After `gh` fails (not a GitHub repo, signed out, offline), wait before
    /// asking again rather than spawning a doomed process every tick.
    static let errorBackoff: TimeInterval = 600
    /// Local git only, so it can run far more often than `gh`.
    static let tipProbeInterval: TimeInterval = 20
    /// How long to keep polling fast after a push before concluding that
    /// this commit gets no CI.
    static let awaitingCIWindow: TimeInterval = 120
    /// How long a sent fix counts as under way before the agent has had a
    /// chance to start working.
    static let fixGracePeriod: TimeInterval = 60
    static let promptLogBudget = 12_000
    static let dismissedDefaultsKey = "ciDismissedFailureCommits"

    init(
        ghService: (any GhServiceProtocol)?,
        sessions: @escaping @MainActor () -> [Session] = { [] },
        defaults: UserDefaults = .standard
    ) {
        self.ghService = ghService
        self.sessions = sessions
        self.defaults = defaults
        self.dismissed = defaults.dictionary(forKey: Self.dismissedDefaultsKey) as? [String: String] ?? [:]
    }

    func status(for sessionID: UUID) -> CIStatus? {
        visibleStatus(for: sessionID)
    }

    /// CI on a commit from before the session began isn't this session's,
    /// unless a pull request ties it to this branch or the user wants it.
    static func isFromBeforeSession(_ status: CIStatus?, tip: CILocalTip?) -> Bool {
        guard let status, status.pullRequest == nil, let commit = status.commitSHA else { return false }
        return tip?.preSessionCommits.contains(commit) == true
    }

    private func visibleStatus(for sessionID: UUID) -> CIStatus? {
        let status = statuses[sessionID]
        return !showsCIBeforeSessionCommits() && Self.isFromBeforeSession(status, tip: tips[sessionID]) ? nil : status
    }

    func snapshot(for sessionID: UUID) -> CISnapshot {
        let status = visibleStatus(for: sessionID)
        let tip = tips[sessionID]
        return CISnapshot(
            status: status,
            tip: tip,
            problem: problems[sessionID],
            lastUpdated: lastUpdated[sessionID],
            fix: activeFix(for: sessionID),
            isDismissed: isDismissed(sessionID),
            hasLoaded: statuses[sessionID] != nil || observed.contains(sessionID) || problems[sessionID] != nil,
            isAwaitingCI: (awaitingCIUntil[sessionID] ?? .distantPast) > Date(),
            isWaitingForFirstCommit: status == nil && !showsCIBeforeSessionCommits()
                && tip.map { $0.preSessionCommits.contains($0.sha) } == true
        )
    }

    /// Sessions whose CI wants the user: a blocking failure on work that can
    /// still change, which nobody has dismissed and no agent is fixing.
    var needsYouSessionIDs: Set<UUID> {
        Set(statuses.keys.compactMap { id in
            guard let status = visibleStatus(for: id) else { return nil }
            let needsYou = status.isActionable && !status.blockingFailures.isEmpty
                && !isDismissed(id) && activeFix(for: id) == nil
            return needsYou ? id : nil
        })
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

    /// Takes this commit's failure out of Needs You. A failure on any later
    /// commit is a new question and asks again.
    func dismissFailure(sessionID: UUID) {
        guard let commit = statuses[sessionID]?.commitSHA else { return }
        dismissed[sessionID.uuidString] = commit
        defaults.set(dismissed, forKey: Self.dismissedDefaultsKey)
    }

    /// The demo fleet has no GitHub remote; it shows CI by seeding it.
    func seed(
        _ seeded: [UUID: CIStatus],
        tips seededTips: [UUID: CILocalTip] = [:],
        fixes seededFixes: [UUID: CIFixAttempt] = [:],
        excerpts seededExcerpts: [Int: String] = [:]
    ) {
        isSeeded = true
        statuses.merge(seeded) { _, new in new }
        tips.merge(seededTips) { _, new in new }
        fixes.merge(seededFixes) { _, new in new }
        excerpts.merge(seededExcerpts) { _, new in new }
        for id in seeded.keys {
            observed.insert(id)
            lastUpdated[id] = Date()
        }
    }

    // MARK: - Failure details

    /// The part of a failed job's log that explains it. Empty for checks
    /// that publish no log, such as external status contexts.
    func excerpt(for check: CICheck, sessionID: UUID) async throws -> String {
        guard let jobID = check.jobID else { return "" }
        if let cached = excerpts[jobID] { return cached }
        let log = try await jobLog(jobID: jobID, sessionID: sessionID)
        let excerpt = await Task.detached { GhJSON.failureExcerpt(log) }.value
        // ponytail: wholesale eviction, an LRU only if re-fetches ever show up.
        if excerpts.count >= 100 { excerpts.removeAll() }
        excerpts[jobID] = excerpt
        return excerpt
    }

    /// Writes a job's whole log to a temporary file for a text viewer.
    func fullLogFile(for check: CICheck, sessionID: UUID) async throws -> URL? {
        guard let jobID = check.jobID else { return nil }
        let log = try await jobLog(jobID: jobID, sessionID: sessionID)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FlotillaCI", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("job-\(jobID).log")
        try log.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func jobLog(jobID: Int, sessionID: UUID) async throws -> String {
        guard let ghService, let repo = sessions().first(where: { $0.id == sessionID })?.worktree?.worktreePath else {
            return ""
        }
        return try await ghService.jobLog(jobID: jobID, at: repo)
    }

    // MARK: - Sending to the agent

    /// One prompt covering every failure to fix, and a warning when some
    /// logs couldn't be fetched. The prompt still links each check then.
    func failurePrompt(sessionID: UUID) async -> (prompt: String, warning: String?) {
        let status = statuses[sessionID]
        let failures = status?.failuresToFix ?? []
        var details: [(check: CICheck, excerpt: String)] = []
        var warning: String?
        for check in failures {
            do {
                let excerpt = try await excerpt(for: check, sessionID: sessionID)
                details.append((check, GhJSON.clipped(excerpt, maxBytes: Self.promptLogBudget / failures.count)))
            } catch {
                warning = "Couldn’t fetch a log: \(error.localizedDescription)"
                details.append((check, ""))
            }
        }
        let branch = sessions().first { $0.id == sessionID }.flatMap(Self.branch(of:)) ?? "this branch"
        return (Self.prompt(failures: details, branch: branch, commitSHA: status?.commitSHA), warning)
    }

    static func prompt(failures: [(check: CICheck, excerpt: String)], branch: String, commitSHA: String?) -> String {
        var text = "CI failed on \(branch)"
        if let commitSHA { text += " at commit \(commitSHA.prefix(7))" }
        text += ".\n"
        for (check, excerpt) in failures {
            text += "\n## \(check.name)"
            if let workflow = check.workflowName, workflow != check.name { text += " (\(workflow))" }
            text += "\n"
            if let url = check.url { text += "Details: \(url.absoluteString)\n" }
            if let jobID = check.jobID {
                text += "Full log, once the run has finished: `gh run view --job \(jobID) --log-failed`\n"
            }
            if !excerpt.isEmpty { text += "\n```\n\(excerpt)\n```\n" }
        }
        text += "\nFind the cause, fix it, and push the fix."
        return text
    }

    /// Builds and sends the prompt. Only ever runs from a user's click.
    func sendFailuresToAgent(sessionID: UUID) async throws {
        try await deliverFixPrompt(await failurePrompt(sessionID: sessionID).prompt, to: sessionID)
    }

    func deliverFixPrompt(_ prompt: String, to sessionID: UUID) async throws {
        try await deliver?(prompt, sessionID)
        fixes[sessionID] = CIFixAttempt(commitSHA: statuses[sessionID]?.commitSHA, sentAt: Date())
        // Nothing else re-renders when the grace period lapses on an agent
        // that never started; reassigning notifies observers.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.fixGracePeriod))
            if let self, let attempt = self.fixes[sessionID] { self.fixes[sessionID] = attempt }
        }
        await refresh(sessionID: sessionID)
    }

    /// Under way while the agent works, or briefly after sending, before it
    /// has had a chance to start. Stopping without a new commit ends it.
    static func isFixUnderWay(_ fix: CIFixAttempt, sessionStatus: SessionStatus?, now: Date) -> Bool {
        sessionStatus == .working || now.timeIntervalSince(fix.sentAt) < fixGracePeriod
    }

    private func activeFix(for sessionID: UUID) -> CIFixAttempt? {
        guard let fix = fixes[sessionID] else { return nil }
        let status = sessions().first { $0.id == sessionID }?.status
        return Self.isFixUnderWay(fix, sessionStatus: status, now: Date()) ? fix : nil
    }

    private func isDismissed(_ sessionID: UUID) -> Bool {
        guard let commit = statuses[sessionID]?.commitSHA else { return false }
        return dismissed[sessionID.uuidString] == commit
    }

    // MARK: - Polling

    private func pollDueSessions() async {
        let current = sessions()
        forgetSessions(notIn: Set(current.map(\.id)), fleetIsLoaded: !current.isEmpty)

        for session in current where Self.branch(of: session) != nil {
            guard !inFlight.contains(session.id) else { continue }
            await probeTipIfDue(session)
            if isFinished(session.id) { continue }
            guard (nextPoll[session.id] ?? .distantPast) <= Date() else { continue }
            await poll(session)
        }
    }

    private func forgetSessions(notIn liveIDs: Set<UUID>, fleetIsLoaded: Bool) {
        for id in Set(statuses.keys).union(tips.keys).union(problems.keys).subtracting(liveIDs) {
            statuses[id] = nil
            tips[id] = nil
            problems[id] = nil
            lastUpdated[id] = nil
            fixes[id] = nil
            observed.remove(id)
            awaitingCIUntil[id] = nil
            nextPoll[id] = nil
            nextTipProbe[id] = nil
        }
        // An empty fleet may just not have loaded yet; dismissals outlive launches.
        guard fleetIsLoaded else { return }
        let liveKeys = Set(liveIDs.map(\.uuidString))
        let kept = dismissed.filter { liveKeys.contains($0.key) }
        if kept.count != dismissed.count {
            dismissed = kept
            defaults.set(kept, forKey: Self.dismissedDefaultsKey)
        }
    }

    /// A finished PR only stops polling while the worktree is still at its
    /// head; new commits on the branch are new work.
    private func isFinished(_ sessionID: UUID) -> Bool {
        guard let status = statuses[sessionID], status.isSettledForever else { return false }
        return tips[sessionID].map { $0.sha == status.pullRequest?.headSHA } ?? true
    }

    /// Notices a push without asking GitHub: the remote-tracking refs move
    /// locally. A fresh push is the moment fast polling pays off.
    private func probeTipIfDue(_ session: Session) async {
        let now = Date()
        guard let ghService, let repo = session.worktree?.worktreePath,
              (nextTipProbe[session.id] ?? .distantPast) <= now else { return }
        nextTipProbe[session.id] = now.addingTimeInterval(Self.tipProbeInterval)
        guard let tip = try? await ghService.localTip(at: repo), tip != tips[session.id] else { return }
        let previous = tips[session.id]
        tips[session.id] = tip
        if previous != nil, tip.isPushed, tip.sha != statuses[session.id]?.commitSHA {
            awaitingCIUntil[session.id] = now.addingTimeInterval(Self.awaitingCIWindow)
            nextPoll[session.id] = now
        }
    }

    private func poll(_ session: Session) async {
        guard !isSeeded, let ghService, let branch = Self.branch(of: session), let repo = session.worktree?.worktreePath,
              inFlight.insert(session.id).inserted else { return }
        defer { inFlight.remove(session.id) }

        if let tip = try? await ghService.localTip(at: repo) { tips[session.id] = tip }
        let previous = statuses[session.id]
        do {
            let fetched = try await ghService.ciStatus(forBranch: branch, at: repo)
            let hadBaseline = !observed.insert(session.id).inserted
            problems[session.id] = nil

            // No answer for this commit (say it isn't pushed yet) says
            // nothing about the last one that had checks, so keep that one.
            let status = fetched ?? (previous?.checks.isEmpty == false ? previous : nil)
            statuses[session.id] = status
            if fetched != nil || previous == nil { lastUpdated[session.id] = Date() }
            if let fix = fixes[session.id], let commit = status?.commitSHA, commit != fix.commitSHA {
                fixes[session.id] = nil
            }
            nextPoll[session.id] = Date().addingTimeInterval(Self.pollInterval(
                status: status,
                tip: tips[session.id],
                awaitingCIUntil: awaitingCIUntil[session.id],
                now: Date()
            ))
            if let fetched, visibleStatus(for: session.id) != nil,
               Self.isNewFailure(previous: previous, current: fetched, hadBaseline: hadBaseline),
               let check = fetched.blockingFailures.first {
                onFailure?(session, check)
            }
        } catch {
            problems[session.id] = CIPollProblem(error: error)
            nextPoll[session.id] = Date().addingTimeInterval(Self.errorBackoff)
        }
    }

    /// Anything still running keeps polling fast, even on a branch that is
    /// already red. So does a just-pushed commit that hasn't reported yet.
    static func pollInterval(status: CIStatus?, tip: CILocalTip?, awaitingCIUntil: Date?, now: Date) -> TimeInterval {
        if status?.hasPendingChecks == true { return pendingInterval }
        let hasNoAnswerYet = status?.commitSHA != tip?.sha || status?.checks.isEmpty != false
        if let awaitingCIUntil, awaitingCIUntil > now, hasNoAnswerYet { return pendingInterval }
        return settledInterval
    }

    /// News is a commit newly blocked by CI. The first answer ever has
    /// nothing to compare against, so a branch already red at launch stays
    /// silent; an empty answer followed by red is a real transition.
    static func isNewFailure(previous: CIStatus?, current: CIStatus, hadBaseline: Bool) -> Bool {
        guard hadBaseline, current.isActionable, !current.blockingFailures.isEmpty else { return false }
        guard let previous, !previous.blockingFailures.isEmpty else { return true }
        return previous.commitSHA != current.commitSHA
    }

    /// Only worktree sessions own a branch tip whose CI is this session's.
    /// A session in the main checkout is usually on the default branch, whose
    /// CI is not this session's result — even though the no-PR path keys
    /// Actions by commit SHA once a worktree branch is known.
    static func branch(of session: Session) -> String? {
        guard let branch = session.worktree?.branchName, !branch.isEmpty else { return nil }
        return branch
    }
}
