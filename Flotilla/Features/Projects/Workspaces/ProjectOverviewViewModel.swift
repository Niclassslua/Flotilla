import Foundation
import Observation
import SessionKit
import GitKit

/// Loads overview data independently from its presentation and navigation.
@Observable @MainActor
final class ProjectOverviewViewModel {
    private(set) var pulse: ProjectPulse = .empty
    private(set) var worktrees: [GitWorktree] = []
    private(set) var snapshots: [URL: WorktreeSnapshot] = [:]
    private(set) var isLoadingWorktrees = false
    private(set) var isSnapshotting = false
    var sessions: [Session] = []
    private let gitService: any GitServiceProtocol
    private var root: URL?
    private var loadGeneration = UUID()
    private var worktreeGeneration = UUID()
    private let commitLimit = 6

    init(gitService: any GitServiceProtocol) {
        self.gitService = gitService
    }

    func load(root: URL) async {
        let generation = UUID()
        loadGeneration = generation
        if self.root != root {
            pulse = .empty
            worktrees = []
            snapshots = [:]
            isLoadingWorktrees = true
            isSnapshotting = false
            worktreeGeneration = UUID()
        }
        self.root = root

        async let pulseTask = ProjectPulse.load(root: root, git: gitService)
        async let worktreesTask = refreshWorktrees(generation: generation)

        let pulse = await pulseTask
        guard !Task.isCancelled, generation == loadGeneration else { return }
        self.pulse = pulse
        await worktreesTask
    }

    func refreshWorktrees() async {
        await refreshWorktrees(generation: loadGeneration)
    }

    private func refreshWorktrees(generation: UUID) async {
        guard let root else { return }
        let currentWorktreeGen = UUID()
        worktreeGeneration = currentWorktreeGen
        if worktrees.isEmpty {
            isLoadingWorktrees = true
        }

        let list = (try? await gitService.listWorktrees(at: root)) ?? []
        guard !Task.isCancelled, generation == loadGeneration, currentWorktreeGen == worktreeGeneration, self.root == root else { return }

        // Phase 1: Publish worktrees immediately (~30ms)
        self.worktrees = list
        self.isLoadingWorktrees = false

        guard !list.isEmpty else {
            self.isSnapshotting = false
            return
        }

        self.isSnapshotting = true

        // Phase 2: Prioritize snapshots.
        // Active sessions first, then main worktree, then alphabetical order.
        let activePaths = Set(sessions.compactMap { ($0.worktree?.worktreePath ?? $0.workingDirectory).standardizedFileURL })
        let priorityPaths = list.sorted { lhs, rhs in
            if lhs.isMainWorktree != rhs.isMainWorktree { return lhs.isMainWorktree }
            let ls = activePaths.contains(lhs.path.standardizedFileURL)
            let rs = activePaths.contains(rhs.path.standardizedFileURL)
            if ls != rs { return ls }
            return lhs.branch < rhs.branch
        }.map(\.path)

        var pendingSnapshots: [URL: WorktreeSnapshot] = [:]
        var countSinceLastPublish = 0
        let immediateCount = min(12, priorityPaths.count)
        var totalStreamed = 0

        for await (path, snapshot) in WorktreeSnapshot.streamSnapshots(paths: priorityPaths, git: gitService) {
            guard !Task.isCancelled, generation == loadGeneration, currentWorktreeGen == self.worktreeGeneration, self.root == root else { return }
            pendingSnapshots[path.standardizedFileURL] = snapshot
            totalStreamed += 1
            countSinceLastPublish += 1

            let batchThreshold = totalStreamed <= immediateCount ? 2 : 6
            if countSinceLastPublish >= batchThreshold || totalStreamed == priorityPaths.count {
                for (url, snap) in pendingSnapshots {
                    self.snapshots[url] = snap
                }
                pendingSnapshots.removeAll(keepingCapacity: true)
                countSinceLastPublish = 0
            }
        }

        if !pendingSnapshots.isEmpty {
            for (url, snap) in pendingSnapshots {
                self.snapshots[url] = snap
            }
        }

        if generation == loadGeneration, currentWorktreeGen == self.worktreeGeneration {
            self.isSnapshotting = false
        }
    }

    // MARK: - Data

    /// Number of sessions that were active or created within the past week (last 7 days).
    static func sessionsUsedThisWeek(in sessions: [Session], now: Date = Date(), calendar: Calendar = .current) -> Int {
        let cutoff = calendar.date(byAdding: .day, value: -7, to: now) ?? .distantPast
        return sessions.filter {
            $0.lastActiveAt >= cutoff || $0.createdAt >= cutoff
        }.count
    }

    var sessionsThisWeek: Int {
        Self.sessionsUsedThisWeek(in: sessions)
    }

    private var attentionSessions: [Session] {
        sessions
            .filter { $0.status == .waitingForInput }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    /// Non-attention sessions and recent commits, newest first, bucketed by day.
    private var dayGroups: [(label: String, items: [StreamEntry])] {
        let attentionIDs = Set(attentionSessions.map(\.id))
        let sessionEntries = sessions
            .filter { !attentionIDs.contains($0.id) }
            .map { StreamEntry(session: $0) }
        let commitEntries = pulse.recentCommits.prefix(commitLimit).map { StreamEntry(commit: $0) }

        let merged = (sessionEntries + commitEntries).sorted { $0.date > $1.date }
        guard !merged.isEmpty else { return [] }

        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [StreamEntry]] = [:]
        for entry in merged {
            let key = Self.dayLabel(for: entry.date, calendar: calendar)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(entry)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private var earlierCommitCount: Int {
        max(0, pulse.recentCommits.count - commitLimit)
    }

    /// The flattened timeline: day/attention bands interleaved with entry rows,
    /// then an "earlier commits" footer. One list so the spine is continuous
    /// within a day and breaks cleanly at each band.
    var timelineElements: [TimelineElement] {
        var out: [TimelineElement] = []

        if !attentionSessions.isEmpty {
            out.append(.band("Needs you"))
            for session in attentionSessions {
                out.append(.entry(StreamEntry(session: session), isLast: false))
            }
        }

        let groups = dayGroups
        for (groupIndex, group) in groups.enumerated() {
            out.append(.band(group.label))
            for (rowIndex, entry) in group.items.enumerated() {
                let lastOverall = groupIndex == groups.count - 1 && rowIndex == group.items.count - 1
                out.append(.entry(entry, isLast: lastOverall && earlierCommitCount == 0))
            }
        }

        if earlierCommitCount > 0 { out.append(.footer(earlierCommitCount)) }
        return out
    }

    private static func dayLabel(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day ?? 0
        if days < 7 {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date)
        }
        return "Earlier"
    }

}

// MARK: - Timeline model

enum TimelineElement: Identifiable {
    case band(String)
    case entry(StreamEntry, isLast: Bool)
    case footer(Int)

    var id: String {
        switch self {
        case .band(let label): return "band-\(label)"
        case .entry(let entry, _): return entry.id
        case .footer: return "footer"
        }
    }
}

struct StreamEntry: Identifiable {
    enum Payload {
        case session(Session)
        case commit(GitCommit)
    }

    let id: String
    let date: Date
    let payload: Payload
    var isAttention = false

    init(session: Session) {
        id = "s-\(session.id)"
        date = session.lastActiveAt
        payload = .session(session)
        isAttention = session.status == .waitingForInput
    }

    init(commit: GitCommit) {
        id = "c-\(commit.sha)"
        date = commit.authorDate
        payload = .commit(commit)
    }

    var timeLabel: String { HomeTimestamp.compact(date) }

    /// Sessions that are live, waiting, or awaiting review get the emphasised
    /// row treatment — bigger title, haloed node, more air.
    var isHero: Bool {
        guard case .session(let session) = payload else { return false }
        return session.status == .working
            || session.status == .waitingForInput
            || session.status == .readyForReview
    }
}

