import SwiftUI
import SessionKit
import GitKit
import DesignSystem

/// The at-a-glance state of a project's main checkout: branch, how far it has
/// drifted from its upstream, the size of the working-copy delta, worktree
/// count, and the last two dozen commits. Loaded once when the workspace
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
        var pulse = ProjectPulse()
        pulse.branch = try? await git.currentBranch(at: root)
        if let status = try? await git.status(at: root) {
            pulse.changedFileCount = status.entries.count
        }
        if let stat = try? await git.diffStat(at: root) {
            pulse.diffStat = stat
        }
        if let unpushed = try? await git.unpushedSHAs(at: root, ref: nil) {
            pulse.unpushedCount = unpushed.count
        }
        if let worktrees = try? await git.listWorktrees(at: root) {
            pulse.worktreeCount = worktrees.count
        }
        if let commits = try? await git.log(at: root, ref: nil, skip: 0, maxCount: 24) {
            pulse.recentCommits = commits
        }
        return pulse
    }
}
