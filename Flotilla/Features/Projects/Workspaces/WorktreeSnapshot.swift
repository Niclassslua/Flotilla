import Foundation
import GitKit

/// The working-copy state of a single worktree: how far its files have drifted
/// from HEAD and how far its branch has drifted from its upstream. The context
/// column loads one per worktree so a row can say what is actually going on in
/// that checkout instead of only naming its branch.
struct WorktreeSnapshot: Equatable, Sendable {
    var changedFileCount = 0
    var diffStat = GitDiffStat(additions: 0, deletions: 0)
    var unpushedCount = 0

    var isClean: Bool { changedFileCount == 0 }

    static func load(path: URL, git: any GitServiceProtocol) async -> WorktreeSnapshot {
        async let statusTask = try? git.status(at: path)
        async let statTask = try? git.diffStat(at: path)
        async let unpushedTask = try? git.unpushedSHAs(at: path, ref: nil)

        var snapshot = WorktreeSnapshot()
        if let status = await statusTask {
            snapshot.changedFileCount = status.entries.count
        }
        if let stat = await statTask {
            snapshot.diffStat = stat
        }
        if let unpushed = await unpushedTask {
            snapshot.unpushedCount = unpushed.count
        }
        return snapshot
    }

    /// Loads every worktree's snapshot, a handful of checkouts at a time — each
    /// one spawns three `git` processes, so an unbounded group over a project
    /// with two dozen worktrees would stampede.
    static func loadAll(
        paths: [URL],
        git: any GitServiceProtocol,
        maxConcurrent: Int = 4
    ) async -> [URL: WorktreeSnapshot] {
        var result: [URL: WorktreeSnapshot] = [:]
        for await (path, snapshot) in streamSnapshots(paths: paths, git: git, maxConcurrent: maxConcurrent) {
            result[path.standardizedFileURL] = snapshot
        }
        return result
    }

    /// Streams snapshots as each worktree completes, preserving bounded concurrency.
    static func streamSnapshots(
        paths: [URL],
        git: any GitServiceProtocol,
        maxConcurrent: Int = 4
    ) -> AsyncStream<(URL, WorktreeSnapshot)> {
        AsyncStream { continuation in
            let task = Task {
                var remaining = paths.makeIterator()
                await withTaskGroup(of: (URL, WorktreeSnapshot).self) { group in
                    var inFlight = 0
                    while inFlight < maxConcurrent, let path = remaining.next() {
                        group.addTask { (path, await load(path: path, git: git)) }
                        inFlight += 1
                    }
                    while let (path, snapshot) = await group.next() {
                        if Task.isCancelled { break }
                        continuation.yield((path, snapshot))
                        if let path = remaining.next() {
                            group.addTask { (path, await load(path: path, git: git)) }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
