import SwiftUI
import SessionKit
import GitKit

/// Compact GitHub-style line-count badge: `+12` in green, `−4` in red,
/// monospaced digits on subtly tinted chips. A clean tree renders nothing —
/// absence is the "no changes" state, so the badge never shouts.
struct DiffStatBadge: View {
    let stat: GitDiffStat

    var body: some View {
        HStack(spacing: 3) {
            if stat.additions > 0 {
                chip("+\(stat.additions)", color: .green)
            }
            if stat.deletions > 0 {
                chip("−\(stat.deletions)", color: .red)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stat.additions) addition\(stat.additions == 1 ? "" : "s"), \(stat.deletions) deletion\(stat.deletions == 1 ? "" : "s")")
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// Polls `diffStat(at:)` for a session's repo (its worktree when it has
/// one) while the row/card is on screen, and renders a `DiffStatBadge`.
/// The task is tied to the repo path so a session that gains a worktree
/// after creation switches targets without a view rebuild. Errors render
/// nothing: a stale badge is worse than no badge.
///
/// Layout note: `.task` must sit on the outer `HStack`, not on a view whose
/// body resolves to `EmptyView` — SwiftUI never fires a task attached to a
/// subtree that renders nothing, which would deadlock the poll (stat stays
/// nil, badge never appears). The container is always present (even at zero
/// width for a clean tree), so the initial poll is guaranteed to run.
struct SessionDiffStatView: View {
    let session: Session
    let gitService: any GitServiceProtocol

    @State private var stat: GitDiffStat?

    private var repoPath: URL {
        session.worktree?.worktreePath ?? session.workingDirectory
    }

    var body: some View {
        HStack(spacing: 3) {
            if let stat {
                DiffStatBadge(stat: stat)
            }
        }
        .accessibilityIdentifier("DiffStatBadge-\(session.title)")
        .task(id: repoPath) { await monitor() }
    }

    private func monitor() async {
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    private func refresh() async {
        let start = DispatchTime.now().uptimeNanoseconds
        stat = try? await gitService.diffStat(at: repoPath)
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
        PerfLog.event("diffStat \(session.title) \(String(format: "%.1f", milliseconds))ms (3 git processes) at \(repoPath.lastPathComponent)")
    }
}