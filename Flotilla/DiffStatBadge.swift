import SwiftUI
import SessionKit
import GitKit
import DesignSystem

/// Compact GitHub-style line-count badge: `+12` in green, `−4` in red,
/// monospaced digits on subtly tinted chips. A clean tree renders nothing —
/// absence is the "no changes" state, so the badge never shouts.
struct DiffStatBadge: View {
    let stat: GitDiffStat

    var body: some View {
        HStack(spacing: FlotillaSpacing.xSmall) {
            if stat.additions > 0 {
                chip("+\(stat.additions)", color: FlotillaColors.statusWorking)
            }
            if stat.deletions > 0 {
                chip("−\(stat.deletions)", color: FlotillaColors.statusCrashed)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stat.additions) addition\(stat.additions == 1 ? "" : "s"), \(stat.deletions) deletion\(stat.deletions == 1 ? "" : "s")")
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// Renders the shared per-session diff stat from `DiffStatStore`. The store
/// polls once per session (refcounted across all badge instances on screen)
/// and hands the cached value out synchronously, so a dozen rows/cards for
/// the same session cost exactly one polling task. Errors render nothing:
/// a stale badge is worse than no badge.
///
/// Layout note: `.onAppear`/`.onDisappear` must sit on the outer `HStack`,
/// not on a view whose body resolves to `EmptyView` — SwiftUI never fires
/// lifecycle callbacks attached to a subtree that renders nothing, which
/// would deadlock the refcount (stat stays nil, badge never appears). The
/// container is always present (even at zero width for a clean tree), so the
/// watch is guaranteed to attach.
struct SessionDiffStatView: View {
    let session: Session
    let diffStatStore: DiffStatStore?

    private var repoPath: URL {
        session.worktree?.worktreePath ?? session.workingDirectory
    }

    var body: some View {
        HStack(spacing: 3) {
            if let stat = diffStatStore?.stat(for: session.id) {
                DiffStatBadge(stat: stat)
            }
        }
        .accessibilityIdentifier("DiffStatBadge-\(session.title)")
        .onAppear {
            diffStatStore?.watch(sessionID: session.id, repoPath: repoPath)
        }
        .onChange(of: repoPath) { _, newPath in
            diffStatStore?.setRepoPath(newPath, sessionID: session.id)
        }
        .onDisappear {
            diffStatStore?.unwatch(sessionID: session.id)
        }
    }
}