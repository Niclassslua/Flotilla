import Foundation
import Observation
import SessionKit
import GitKit

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
    /// Project ID → week start → net lines (additions − deletions) that week.
    var netLinesByWeek: [UUID: [Date: Int]] = [:]

    mutating func merge(_ other: HomeActivity) {
        commitsByDay.merge(other.commitsByDay, uniquingKeysWith: +)
        linesByDay.merge(other.linesByDay, uniquingKeysWith: +)
        contributions.merge(other.contributions, uniquingKeysWith: +)
        netLinesByWeek.merge(other.netLinesByWeek) { lhs, rhs in lhs.merging(rhs, uniquingKeysWith: +) }
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
            activity.contributions[contributor(of: commit, recorded: recorded[commit.sha]), default: 0] += 1
        }
        return activity
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
    private(set) var activity: HomeActivity?
    private var lastCompleted: Date?
    private var lastProjectIDs: Set<UUID> = []

    /// A visit within this window of a completed refresh, with the same
    /// projects, reuses what's loaded.
    static let freshness: TimeInterval = 60

    func refresh(store: AppStore) async {
        let projects = store.projects
        let projectIDs = Set(projects.map(\.id))
        if let lastCompleted, projectIDs == lastProjectIDs,
           Date().timeIntervalSince(lastCompleted) < Self.freshness {
            return
        }
        repoStates = repoStates.filter { projectIDs.contains($0.key) }

        let git = store.gitService
        for project in projects {
            guard !Task.isCancelled else { return }
            repoStates[project.id] = await HomeRepoState.load(root: project.rootPath, git: git)
        }

        var merged = HomeActivity()
        for project in projects {
            guard !Task.isCancelled else { return }
            merged.merge(await HomeActivity.load(
                project: project,
                sessions: store.sessions(for: project),
                git: git,
                resolver: store.commitAttribution
            ))
        }
        activity = merged
        lastCompleted = Date()
        lastProjectIDs = projectIDs
    }
}
