import SwiftUI
import SessionKit
import GitKit
import DesignSystem

/// The at-a-glance state of a project's main checkout: branch, how far it has
/// drifted from its upstream, the size of the working-copy delta, worktree
/// count, and its recent commits. Loaded once when the workspace
/// appears and feeds the masthead instrument row, the activity feed, and the
/// context column.
struct ProjectPulse: Equatable, Sendable {
    var branch: String?
    var changedFileCount: Int = 0
    var diffStat: GitDiffStat = GitDiffStat(additions: 0, deletions: 0)
    var unpushedCount: Int = 0
    var worktreeCount: Int = 0
    var recentCommits: [GitCommit] = []

    var isClean: Bool { changedFileCount == 0 }
    var lastCommit: GitCommit? { recentCommits.first }

    static let empty = ProjectPulse()

    static func load(root: URL, git: any GitServiceProtocol) async -> ProjectPulse {
        async let branchTask = try? git.currentBranch(at: root)
        async let statusTask = try? git.status(at: root)
        async let statTask = try? git.diffStat(at: root)
        async let unpushedTask = try? git.unpushedSHAs(at: root, ref: nil)
        async let worktreesTask = try? git.listWorktrees(at: root)
        async let commitsTask = try? git.log(at: root, ref: nil, skip: 0, maxCount: 60)

        var pulse = ProjectPulse()
        pulse.branch = await branchTask
        if let status = await statusTask {
            pulse.changedFileCount = status.entries.count
        }
        if let stat = await statTask {
            pulse.diffStat = stat
        }
        if let unpushed = await unpushedTask {
            pulse.unpushedCount = unpushed.count
        }
        if let worktrees = await worktreesTask {
            pulse.worktreeCount = worktrees.count
        }
        if let commits = await commitsTask {
            pulse.recentCommits = commits
        }
        return pulse
    }
}
