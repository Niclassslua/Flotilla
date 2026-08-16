import Foundation
import SessionKit
import GitKit

/// Shared, refcounted per-session git diff-stat poller. Every badge instance
/// for the same session calls `watch`; the first one starts a single polling
/// task (one per session, not one per badge) and the last one to disappear
/// cancels it. This caps the git subprocess churn to 3 processes per session
/// per interval regardless of how many rows/cards are on screen.
@Observable @MainActor
final class DiffStatStore {
    private let gitService: any GitServiceProtocol
    private(set) var stats: [UUID: GitDiffStat] = [:]
    private var watchers: [UUID: Int] = [:]
    private var paths: [UUID: URL] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(gitService: any GitServiceProtocol) {
        self.gitService = gitService
    }

    func stat(for sessionID: UUID) -> GitDiffStat? {
        stats[sessionID]
    }

    func watch(sessionID: UUID, repoPath: URL) {
        let count = watchers[sessionID] ?? 0
        watchers[sessionID] = count + 1
        guard count == 0 else { return }
        start(sessionID: sessionID, repoPath: repoPath)
    }

    /// Update the poll target for an already-watched session (e.g. it gained
    /// a worktree after creation) without bumping the reference count.
    func setRepoPath(_ path: URL, sessionID: UUID) {
        guard let count = watchers[sessionID], count > 0 else { return }
        if paths[sessionID] != path {
            tasks[sessionID]?.cancel()
            start(sessionID: sessionID, repoPath: path)
        }
    }

    func unwatch(sessionID: UUID) {
        guard let count = watchers[sessionID] else { return }
        if count > 1 {
            watchers[sessionID] = count - 1
        } else {
            watchers[sessionID] = nil
            paths[sessionID] = nil
            tasks[sessionID]?.cancel()
            tasks[sessionID] = nil
            stats[sessionID] = nil
        }
    }

    private func start(sessionID: UUID, repoPath: URL) {
        paths[sessionID] = repoPath
        tasks[sessionID] = Task { [weak self] in
            await self?.refresh(sessionID: sessionID, repoPath: repoPath)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                await self?.refresh(sessionID: sessionID, repoPath: repoPath)
            }
        }
    }

    private func refresh(sessionID: UUID, repoPath: URL) async {
        let start = DispatchTime.now().uptimeNanoseconds
        stats[sessionID] = try? await gitService.diffStat(at: repoPath)
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
        PerfLog.event("diffStat \(sessionID.uuidString) \(String(format: "%.1f", milliseconds))ms (3 git processes) at \(repoPath.lastPathComponent)")
    }
}