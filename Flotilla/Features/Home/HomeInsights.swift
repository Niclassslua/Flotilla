import Foundation
import Observation
import SessionKit
import GitKit
import PersistenceKit

// MARK: - Repository State

/// What a project card says about its main checkout: the loose ends you'd
/// otherwise only discover after opening the project.
struct HomeRepoState: Equatable, Sendable {
    var branch: String?
    var changedFileCount = 0
    var diffStat = GitDiffStat.zero
    var unpushedCount = 0
    /// Linked worktrees only — the main checkout isn't a loose end.
    var worktreeCount = 0

    var hasUncommittedWork: Bool { changedFileCount > 0 }
    var isSettled: Bool { changedFileCount == 0 && unpushedCount == 0 }

    static func load(root: URL, git: any GitServiceProtocol) async -> HomeRepoState {
        async let branch = try? git.currentBranch(at: root)
        async let status = try? git.status(at: root)
        async let diffStat = try? git.diffStat(at: root)
        async let unpushed = try? git.unpushedSHAs(at: root, ref: nil)
        async let worktrees = try? git.listWorktrees(at: root)

        var state = HomeRepoState()
        state.branch = await branch
        state.changedFileCount = await status?.entries.count ?? 0
        state.diffStat = await diffStat ?? state.diffStat
        state.unpushedCount = await unpushed?.count ?? 0
        state.worktreeCount = await worktrees?.filter { !$0.isMainWorktree }.count ?? 0
        return state
    }
}

// MARK: - Activity

extension GitDiffStat {
    static let zero = GitDiffStat(additions: 0, deletions: 0)
}

/// Who made a commit, for the agent-share stat.
enum HomeContributor: Hashable, Sendable {
    case agent(AgentKind)
    case you
}

/// Git activity across every project, bucketed for the stats section.
/// Built from each project's HEAD history; merges are skipped because
/// `git log --numstat` gives them no line counts and they'd double-count days.
struct HomeActivity: Equatable, Sendable {
    static let heatmapWeeks = 53
    static let rhythmDays = 28
    static let shareDays = 30
    static let growthWeeks = 12
    /// Per project. A repository committing more than this in a year
    /// shows a heatmap that starts later than the window — an honest
    /// truncation rather than an unbounded `git log`.
    static let historyLimit = 1_500

    var commitsByDay: [Date: Int] = [:]
    var linesByDay: [Date: GitDiffStat] = [:]
    var contributions: [HomeContributor: Int] = [:]
    /// Lines by whoever wrote them, same window as `contributions` — the
    /// Agent share widget's large size adds this as a per-agent table.
    var linesByContributor: [HomeContributor: GitDiffStat] = [:]
    /// Project ID → week start → net lines (additions − deletions) that week.
    var netLinesByWeek: [UUID: [Date: Int]] = [:]
    /// Every non-merge commit's author date within the heatmap window —
    /// raw enough for the Busiest hours widget to bucket by weekday and hour
    /// over whichever of its own time windows (30/90/365d) is configured,
    /// without `HomeActivity` needing to know about widget settings.
    var commitTimestamps: [Date] = []

    mutating func merge(_ other: HomeActivity) {
        commitsByDay.merge(other.commitsByDay, uniquingKeysWith: +)
        linesByDay.merge(other.linesByDay, uniquingKeysWith: +)
        contributions.merge(other.contributions, uniquingKeysWith: +)
        linesByContributor.merge(other.linesByContributor, uniquingKeysWith: +)
        netLinesByWeek.merge(other.netLinesByWeek) { lhs, rhs in lhs.merging(rhs, uniquingKeysWith: +) }
        commitTimestamps.append(contentsOf: other.commitTimestamps)
    }

    @MainActor
    static func load(
        project: Project,
        sessions: [Session],
        git: any GitServiceProtocol,
        resolver: (any CommitAttributionResolving)?,
        now: Date = .now,
        calendar: Calendar = .current
    ) async -> HomeActivity {
        guard let history = try? await git.log(at: project.rootPath, ref: nil, skip: 0, maxCount: historyLimit) else {
            return HomeActivity()
        }
        let today = calendar.startOfDay(for: now)
        let heatmapStart = calendar.date(byAdding: .day, value: -(heatmapWeeks * 7), to: today) ?? today
        let rhythmStart = calendar.date(byAdding: .day, value: -(rhythmDays - 1), to: today) ?? today
        let shareStart = calendar.date(byAdding: .day, value: -(shareDays - 1), to: today) ?? today
        let growthStart = calendar.date(byAdding: .weekOfYear, value: -(growthWeeks - 1), to: startOfWeek(today, calendar)) ?? today

        let commits = history.filter { !$0.isMerge && $0.authorDate >= heatmapStart }
        var activity = HomeActivity()
        var weekly: [Date: Int] = [:]
        for commit in commits {
            let day = calendar.startOfDay(for: commit.authorDate)
            activity.commitsByDay[day, default: 0] += 1
            activity.commitTimestamps.append(commit.authorDate)
            if day >= rhythmStart {
                activity.linesByDay[day] = activity.linesByDay[day, default: .zero] + commit.stat
            }
            if day >= growthStart {
                weekly[startOfWeek(day, calendar), default: 0] += commit.stat.additions - commit.stat.deletions
            }
        }
        if !weekly.isEmpty { activity.netLinesByWeek[project.id] = weekly }

        let recent = commits.filter { $0.authorDate >= shareStart }
        let recorded = await resolver?.attributions(
            forCommits: recent.map(\.sha),
            repoPath: project.rootPath,
            sessions: sessions
        ) ?? [:]
        for commit in recent {
            let who = contributor(of: commit, recorded: recorded[commit.sha])
            activity.contributions[who, default: 0] += 1
            activity.linesByContributor[who] = (activity.linesByContributor[who] ?? .zero) + commit.stat
        }
        return activity
    }

    /// The heatmap's own window start — shared by every widget that reads
    /// `commitsByDay`/`commitTimestamps` (Streak, Today, Busiest hours) so
    /// they all agree with the heatmap on how far back "recent" reaches.
    static func windowStart(weeksAgo weeks: Int, now: Date = .now, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        let thisWeek = startOfWeek(today, calendar)
        return calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) ?? today
    }

    /// Consecutive days with a commit, ending today — or yesterday, so a
    /// streak isn't "broken" before there's been a chance to commit today.
    func currentStreak(calendar: Calendar = .current, now: Date = .now) -> Int {
        let today = calendar.startOfDay(for: now)
        var day = commitsByDay[today, default: 0] > 0 ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        var streak = 0
        while commitsByDay[day, default: 0] > 0 {
            streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }

    /// Longest run of consecutive committed days within `heatmapWeeks`.
    func longestStreak(calendar: Calendar = .current, now: Date = .now) -> Int {
        var longest = 0, run = 0
        var day = Self.windowStart(weeksAgo: Self.heatmapWeeks, now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        while day <= today {
            run = commitsByDay[day, default: 0] > 0 ? run + 1 : 0
            longest = max(longest, run)
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return longest
    }

    /// `[weekday (Mon-first, 0...6)][hour (0...23)] → commit count`, for the
    /// Busiest hours widget's own `windowDays` — filtered from
    /// `commitTimestamps` rather than stored pre-bucketed, since the widget's
    /// window is a per-instance setting.
    func commitsByWeekdayHour(windowDays: Int, calendar: Calendar = .current, now: Date = .now) -> [[Int]] {
        var grid = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        let cutoff = calendar.date(byAdding: .day, value: -windowDays, to: now) ?? now
        for timestamp in commitTimestamps where timestamp >= cutoff {
            // Calendar's `.weekday` is Sunday-first (1...7); shift to
            // Monday-first (0...6) to match every other weekday display here.
            let sundayFirst = calendar.component(.weekday, from: timestamp) - 1
            let mondayFirst = (sundayFirst + 6) % 7
            let hour = calendar.component(.hour, from: timestamp)
            grid[mondayFirst][hour] += 1
        }
        return grid
    }

    /// Same precedence as History, minus the per-branch session walk:
    /// recorded attribution, then the commit's own trailer, then an agent's
    /// git identity. Anything unclaimed is yours.
    private static func contributor(of commit: GitCommit, recorded: CommitAttribution?) -> HomeContributor {
        if let agent = recorded?.agent { return .agent(agent) }
        if let raw = commit.trailers["flotilla-agent"], let agent = AgentKind.fromTrailerValue(raw) { return .agent(agent) }
        if let agent = AgentKind.inferredFromGitIdentity(name: commit.authorName, email: commit.authorEmail) { return .agent(agent) }
        return .you
    }

    static func startOfWeek(_ date: Date, _ calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }
}

// MARK: - Store

/// A session ready for review, summarized for the Review queue widget
/// without the cost of opening the full review window.
struct HomeReviewItem: Identifiable, Equatable, Sendable {
    var id: UUID { session.id }
    var session: Session
    var project: Project
    var stat: GitDiffStat
    var fileCount: Int
}

/// A session waiting on you, for the Needs you widget.
struct HomeWaitingItem: Identifiable, Equatable, Sendable {
    var id: UUID { session.id }
    var session: Session
    var project: Project
    /// When it started waiting — `statusChangedAt`, or `lastActiveAt` for a
    /// session that transitioned before that field existed.
    var since: Date
    /// Set when the session is here because its CI is failing rather than
    /// because the agent is blocked: the first failing check's name.
    var failingCheck: String? = nil
}

/// Home's git-derived data, owned above the dashboard so returning to Home
/// shows the last answer immediately instead of re-reading every repository.
///
/// Projects load one at a time — each spawns a handful of `git` processes,
/// and a library of twenty repositories must not stampede on every visit.
/// Cards fill in first; the activity pass follows.
@Observable
@MainActor
final class HomeInsights {
    private(set) var repoStates: [UUID: HomeRepoState] = [:]
    /// Per project, so a widget's project filter can read one repository's
    /// slice without recomputing it. `activity(for:)` merges across projects
    /// for "All projects".
    private(set) var activityByProject: [UUID: HomeActivity] = [:]
    /// Sessions currently `.readyForReview` / `.waitingForInput`. Loaded
    /// together by `loadReviewItems` since both Review queue and Needs you
    /// widgets are triggered by the same `.reviewQueue` need — a live status
    /// snapshot, not part of the batched git-derived `refresh`.
    private(set) var reviewItems: [HomeReviewItem] = []
    private(set) var waitingItems: [HomeWaitingItem] = []
    private var lastCompleted: Date?
    private var lastProjectIDs: Set<UUID> = []
    private var lastNeeds: Set<HomeDataNeed> = []
    /// The batch-loaded needs `refresh` is currently filling for the first
    /// time — what a widget reads to decide between a skeleton and its
    /// content. A need already holding an answer is never listed, so a
    /// re-refresh updates the numbers in place instead of blanking the card.
    private(set) var loadingNeeds: Set<HomeDataNeed> = []
    /// Distinct from `reviewItems.isEmpty`: an empty queue is a real answer.
    private var hasLoadedReviewItems = false

    /// projectID?|windowDays → (loaded at, result). `nil` project key is
    /// "all projects".
    private var fileChurnCache: [String: (date: Date, result: [String: Int])] = [:]

    /// A visit within this window of a completed refresh, with the same
    /// projects and needs, reuses what's loaded.
    static let freshness: TimeInterval = 60
    static let fileChurnFreshness: TimeInterval = 120

    /// Whether `need`'s first load is still in flight — `true` only before
    /// any answer exists, so a widget skeletons on a cold Home and not on
    /// every subsequent visit.
    func isLoading(_ need: HomeDataNeed) -> Bool { loadingNeeds.contains(need) }

    /// True while any of the kind's batch-loaded needs is still filling.
    /// The per-instance needs (`.fileChurn`, `.permissionLog`,
    /// `.screenshots`) are never listed here — those widgets track their own
    /// load, since each instance queries on its own settings.
    func isLoading(kind: HomeWidgetKind) -> Bool {
        kind.dataNeeds.contains(where: loadingNeeds.contains)
    }

    /// Merged view across every project (or one, when `projectID` is given)
    /// — what a widget without a project filter, or with one set, should
    /// read. `nil` while nothing has loaded for that scope yet.
    func activity(for projectID: UUID? = nil) -> HomeActivity? {
        if let projectID {
            return activityByProject[projectID]
        }
        guard !activityByProject.isEmpty else { return nil }
        var merged = HomeActivity()
        for value in activityByProject.values { merged.merge(value) }
        return merged
    }

    /// Loads only what the currently placed widgets need. `needs` is the
    /// union of every placed widget's `HomeWidgetKind.dataNeeds` for the
    /// two batch-loaded kinds (`.repoState`, `.commitActivity`) — the
    /// per-instance kinds (`.reviewQueue`, `.fileChurn`, `.permissionLog`,
    /// `.screenshots`) are parameterized by a widget's own settings (project,
    /// time window, agent) and are loaded on demand by that widget instead,
    /// through `loadReviewItems`/`fileChurn` below.
    func refresh(store: AppStore, needs: Set<HomeDataNeed>) async {
        let projects = store.projects
        let projectIDs = Set(projects.map(\.id))
        if let lastCompleted, projectIDs == lastProjectIDs, needs == lastNeeds,
           Date().timeIntervalSince(lastCompleted) < Self.freshness {
            return
        }
        repoStates = repoStates.filter { projectIDs.contains($0.key) }
        activityByProject = activityByProject.filter { projectIDs.contains($0.key) }
        loadingNeeds = needs.intersection(Self.batchNeeds).filter { !hasAnswer(for: $0) }
        defer { loadingNeeds = [] }

        let git = store.gitService
        if needs.contains(.repoState) {
            for project in projects {
                guard !Task.isCancelled else { return }
                repoStates[project.id] = await HomeRepoState.load(root: project.rootPath, git: git)
            }
            loadingNeeds.remove(.repoState)
        }

        if needs.contains(.commitActivity) {
            for project in projects {
                guard !Task.isCancelled else { return }
                activityByProject[project.id] = await HomeActivity.load(
                    project: project,
                    sessions: store.sessions(for: project),
                    git: git,
                    resolver: store.commitAttribution
                )
            }
            loadingNeeds.remove(.commitActivity)
        }

        if needs.contains(.reviewQueue) {
            await loadReviewItems(store: store)
            loadingNeeds.remove(.reviewQueue)
        }

        lastCompleted = Date()
        lastProjectIDs = projectIDs
        lastNeeds = needs
    }

    /// The needs `refresh` fills for every widget at once. The rest are
    /// per-widget-instance and loaded by the widget itself.
    private static let batchNeeds: Set<HomeDataNeed> = [.repoState, .commitActivity, .reviewQueue]

    private func hasAnswer(for need: HomeDataNeed) -> Bool {
        switch need {
        case .repoState: !repoStates.isEmpty
        case .commitActivity: !activityByProject.isEmpty
        case .reviewQueue: hasLoadedReviewItems
        default: true
        }
    }

    /// Sessions ready for review, each with its branch diff against the
    /// project's default branch — the same comparison `SessionReviewViewModel
    /// .branchChanges()` makes for the review window itself. Also refreshes
    /// `waitingItems`, the cheaper counterpart for Needs you, since both come
    /// from one pass over `store.sessions`.
    func loadReviewItems(store: AppStore) async {
        let git = store.gitService
        var readyItems: [HomeReviewItem] = []
        var waiting: [HomeWaitingItem] = []
        for session in store.sessions {
            guard !Task.isCancelled else { return }
            guard let project = store.projects.first(where: { $0.id == session.projectID }) else { continue }
            // Red CI outranks Ready for Review — the same rule `FleetAttention`
            // applies to the Dock badge and menu bar.
            if session.status != .waitingForInput,
               let ci = store.ciStatusStore.status(for: session.id), ci.state == .failing {
                waiting.append(HomeWaitingItem(
                    session: session,
                    project: project,
                    since: session.statusChangedAt ?? session.lastActiveAt,
                    failingCheck: ci.failingChecks.first?.name
                ))
                continue
            }
            switch session.status {
            case .readyForReview:
                guard let base = try? await git.defaultBranch(at: session.workingDirectory),
                      let changes = try? await git.changesCompared(to: base, at: session.workingDirectory) else { continue }
                let stat = changes.reduce(GitDiffStat.zero) { $0 + $1.stat }
                readyItems.append(HomeReviewItem(session: session, project: project, stat: stat, fileCount: changes.count))
            case .waitingForInput:
                waiting.append(HomeWaitingItem(session: session, project: project, since: session.statusChangedAt ?? session.lastActiveAt))
            default:
                break
            }
        }
        // Oldest wait first in both: the session that's been sitting longest
        // is the one a "review/attend to oldest" action should open.
        hasLoadedReviewItems = true
        reviewItems = readyItems.sorted { ($0.session.statusChangedAt ?? $0.session.lastActiveAt) < ($1.session.statusChangedAt ?? $1.session.lastActiveAt) }
        waitingItems = waiting.sorted { $0.since < $1.since }
    }

    /// Edit counts per file over `windowDays`, across `projectIDs` (`nil` is
    /// every project) — the Hot files widget's own data, loaded and cached
    /// per (scope, window) since that's a per-widget-instance setting the
    /// batched `refresh` doesn't know about.
    func fileChurn(store: AppStore, projectID: UUID?, windowDays: Int) async -> [String: Int] {
        let key = "\(projectID?.uuidString ?? "all")|\(windowDays)"
        if let cached = fileChurnCache[key], Date().timeIntervalSince(cached.date) < Self.fileChurnFreshness {
            return cached.result
        }
        let projects = projectID.flatMap { id in store.projects.filter { $0.id == id } } ?? store.projects
        let since = Calendar.current.date(byAdding: .day, value: -windowDays, to: .now) ?? .now
        var merged: [String: Int] = [:]
        for project in projects {
            guard !Task.isCancelled else { return merged }
            guard let churn = try? await store.gitService.fileChurn(at: project.rootPath, since: since) else { continue }
            merged.merge(churn, uniquingKeysWith: +)
        }
        fileChurnCache[key] = (Date(), merged)
        return merged
    }

    /// Which permissions were asked most, over `windowDays`, optionally
    /// narrowed to one project and/or agent — Top permissions' own data,
    /// read straight from `store.permissionLogStore`. Not cached: the store
    /// query is a single indexed local read, cheap enough to run on appear.
    func topPermissions(store: AppStore, projectID: UUID?, windowDays: Int, agent: AgentKind?) -> [PermissionPatternCount] {
        let since = Calendar.current.date(byAdding: .day, value: -windowDays, to: .now) ?? .now
        let sessionIDs = projectID.map { id in
            store.sessions.filter { $0.projectID == id }.map(\.id.uuidString)
        }
        return (try? store.permissionLogStore.topPatterns(
            since: since,
            agent: agent?.rawValue,
            sessionIDs: sessionIDs
        )) ?? []
    }
}
