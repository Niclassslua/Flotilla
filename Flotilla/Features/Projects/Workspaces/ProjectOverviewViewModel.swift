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
            worktreeGeneration = UUID()
        }
        self.root = root
        let pulse = await ProjectPulse.load(root: root, git: gitService)
        guard !Task.isCancelled, generation == loadGeneration else { return }
        self.pulse = pulse
        await refreshWorktrees()
    }

    func refreshWorktrees() async {
        guard let root else { return }
        let generation = UUID()
        worktreeGeneration = generation
        let list = (try? await gitService.listWorktrees(at: root)) ?? []
        let snapshots = await WorktreeSnapshot.loadAll(paths: list.map(\.path), git: gitService)
        guard !Task.isCancelled, generation == worktreeGeneration, self.root == root else { return }
        worktrees = list
        self.snapshots = snapshots
    }

    // MARK: - Data

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

