import SwiftUI
import SessionKit
import DesignSystem
import GitKit

// MARK: - Signals

/// The four signals a board card exists to show, resolved in one place so
/// the layout below reads as pure arrangement.
struct KanbanCardSignals {
    let session: Session
    let stat: GitDiffStat?
    let lastOutput: String?
    var ciState: CICheckState? = nil

    var statusColor: Color { StatusPresentation.color(for: session.status) }
    var statusLabel: String { StatusPresentation.label(for: session.status, waitingReason: session.waitingReason) }
    var statusGlyph: String { StatusPresentation.glyph(for: session.status, waitingReason: session.waitingReason) }

    var branch: String? { session.worktree?.branchName }

    /// Wants attention now: blocked on the user, or dead.
    var isBlocking: Bool { session.status == .waitingForInput || session.status == .crashed }

    /// Coarse "how long since this last moved", in the sidebar's register.
    var elapsed: String {
        let seconds = max(0, Date().timeIntervalSince(session.lastActiveAt))
        switch seconds {
        case ..<90: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }
}

/// Reads the two polled stores and owns the `watch`/`unwatch` refcount, so
/// the layout never has to think about the polling lifecycle.
struct KanbanCard: View {
    let session: Session
    /// The card's project name, shown only when the board is mixing projects;
    /// `nil` on a single-project board, where it would be noise.
    var projectName: String? = nil
    let diffStatStore: DiffStatStore?
    let activityStore: SessionActivityStore?
    var ciStatusStore: CIStatusStore? = nil
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onRestart: () -> Void

    private var repoPath: URL {
        session.worktree?.worktreePath ?? session.workingDirectory
    }

    private var signals: KanbanCardSignals {
        KanbanCardSignals(
            session: session,
            stat: diffStatStore?.stat(for: session.id),
            lastOutput: activityStore?.lastOutputLine(for: session.id),
            ciState: ciStatusStore?.status(for: session.id)?.state
        )
    }

    var body: some View {
        GlassCard(signals: signals, projectName: projectName)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onOpen)
            .contextMenu {
                Button("Open Session", action: onOpen)
                Button("Restart Session", action: onRestart)
                Divider()
                Button("Delete Session…", role: .destructive, action: onDelete)
            }
            .onAppear {
                diffStatStore?.watch(sessionID: session.id, repoPath: repoPath)
            }
            .onChange(of: repoPath) { _, newPath in
                diffStatStore?.setRepoPath(newPath, sessionID: session.id)
            }
            .onDisappear {
                diffStatStore?.unwatch(sessionID: session.id)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("KanbanCard-\(session.title)")
    }
}

// MARK: - Layout

/// A material card lit from the top-left by the status colour.
///
/// Five bands, each with one job and a fixed vertical position, so a column
/// of cards can be read down a single band at a time:
///
/// 1. provenance — which agent, how long since it moved
/// 2. identity — the title, the largest thing on the card
/// 3. state — the status chip, with churn pinned to the trailing edge
/// 4. location — the branch, alone on its line so it is never crushed
/// 5. liveness — the agent's most recent output
///
/// Churn is trailing-aligned rather than trailing the status chip: status
/// labels vary from "Working" to "Ready for Review", and letting the number
/// float behind them put it at a different x on every card, which is exactly
/// what a column of numbers must not do.
private struct GlassCard: View {
    let signals: KanbanCardSignals
    var projectName: String? = nil

    private var status: SessionStatus? { signals.session.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let projectName {
                projectEyebrow(projectName)
            }
            provenanceRow
            title
            stateRow
            if let branch = signals.branch {
                branchRow(branch)
            }
            Divider().opacity(0.5)
            OutputLine(text: signals.lastOutput)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RadialGradient(
                colors: [signals.statusColor.opacity(signals.isBlocking ? 0.3 : 0.17), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 220
            )
        }
        .flotillaLiquidSurface(
            FlotillaColors.surface,
            cornerRadius: FlotillaRadius.panel,
            glassTintOpacity: FlotillaGlassTint.elevated
        )
        .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            signals.statusColor.opacity(0.5),
                            FlotillaColors.separator.opacity(0.5),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .flotillaShadow(.level2)
        // The status colour bleeds into the light, the border, and the chip;
        // animating on it lets all three cross-fade together when a session
        // changes state in place (rather than by being dragged).
        .animation(FlotillaMotion.normal.curve, value: status)
        .animation(FlotillaMotion.normal.curve, value: signals.session.waitingReason)
    }

    /// A quiet kicker naming the card's project, one line above everything
    /// else. Only rendered on a board that mixes projects.
    private func projectEyebrow(_ name: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.system(size: 9))
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(FlotillaColors.textTertiary)
    }

    private var provenanceRow: some View {
        HStack(spacing: 5) {
            ProviderLogo(agent: signals.session.agent)
                .frame(width: 12, height: 12)
            Text(signals.session.agent.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(FlotillaColors.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(signals.elapsed)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(FlotillaColors.textTertiary)
                .fixedSize()
        }
    }

    private var title: some View {
        Text(signals.session.title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(FlotillaColors.textPrimary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stateRow: some View {
        HStack(spacing: 8) {
            statusChip
            CIStatusGlyph(state: signals.ciState)
            Spacer(minLength: 8)
            ChurnText(stat: signals.stat)
        }
    }

    private var statusChip: some View {
        HStack(spacing: 4) {
            Image(systemName: signals.statusGlyph)
                .font(.system(size: 10, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
            Text(signals.statusLabel)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .foregroundStyle(signals.statusColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(signals.statusColor.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(signals.statusColor.opacity(0.3), lineWidth: 0.5))
        .fixedSize()
    }

    /// Branch names are long and their meaning is at both ends
    /// (`flotilla/` prefix, the topic at the tail), so this gets the full
    /// card width and truncates in the middle rather than dropping the tail.
    private func branchRow(_ branch: String) -> some View {
        HStack(spacing: 5) {
            GitBranchIcon(size: 10)
                .foregroundStyle(FlotillaColors.textTertiary)
            Text(BranchNaming.displayName(for: branch))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(FlotillaColors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(BranchNaming.displayName(for: branch))
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Parts

/// `+142 −31`, or nothing on a clean tree — absence is the "no changes"
/// state, same as the sidebar badge.
///
/// When the numbers change the digits roll to the new value
/// (`.numericText`) and the whole readout gives a quick scale pop, so churn
/// arriving mid-review is noticeable without being a distraction.
private struct ChurnText: View {
    let stat: GitDiffStat?

    private var additions: Int { stat?.additions ?? 0 }
    private var deletions: Int { stat?.deletions ?? 0 }

    var body: some View {
        Group {
            if let stat, !stat.isEmpty {
                HStack(spacing: 5) {
                    if additions > 0 {
                        Text("+\(additions)")
                            .foregroundStyle(FlotillaColors.statusWorking)
                            .contentTransition(.numericText(value: Double(additions)))
                    }
                    if deletions > 0 {
                        Text("−\(deletions)")
                            .foregroundStyle(FlotillaColors.statusCrashed)
                            .contentTransition(.numericText(value: Double(deletions)))
                    }
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .fixedSize()
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .animation(FlotillaMotion.snappy.curve, value: additions)
        .animation(FlotillaMotion.snappy.curve, value: deletions)
        .keyframeAnimator(initialValue: 1.0, trigger: additions &+ deletions) { view, scale in
            view.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(1.18, duration: 0.12)
                CubicKeyframe(1.0, duration: 0.20)
            }
        }
    }
}

/// The agent's most recent terminal line. The placeholder keeps the card's
/// height stable when a session has produced nothing yet, so a column never
/// reflows as output arrives.
private struct OutputLine: View {
    let text: String?

    var body: some View {
        Text(text ?? "No output yet")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(text == nil ? FlotillaColors.textTertiary.opacity(0.6) : FlotillaColors.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
