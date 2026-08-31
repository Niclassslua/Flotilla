import SwiftUI
import SessionKit
import GitKit
import DesignSystem

/// A live session row in the fleet sidebar. The provider tile carries a
/// status beacon; the metadata line pairs a colored status word with the
/// session's branch or agent, and a compact timestamp keeps recency
/// glanceable. Status is always conveyed by text as well as color.
struct SessionRow: View {
    let session: Session
    var isSelected: Bool = false
    /// `nil` hides the button entirely — grid/kanban call sites that don't
    /// yet wire up a delete flow render the row exactly as before.
    var onDeleteRequested: (() -> Void)? = nil
    /// `nil` hides the working-tree diff badge (e.g. contexts without a
    /// diff stat store); when present, the metadata line ends in `+N −N`.
    var diffStatStore: DiffStatStore? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var beaconPulses = false

    private var statusColor: Color {
        StatusPresentation.color(for: session.status)
    }

    private var isPulsing: Bool {
        session.status == .working && !reduceMotion
    }

    private var needsInput: Bool {
        session.status == .waitingForInput
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            providerTile
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Self.compactTimestamp(for: session.lastActiveAt))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    if let onDeleteRequested {
                        // Always present rather than hover-gated: a
                        // hover-only reveal is unreachable by keyboard/
                        // VoiceOver, and relies on `onHover`, which only
                        // fires for actual pointer movement — never for an
                        // accessibility client driving the button directly.
                        // Kept small and tertiary so it doesn't compete with
                        // the title at rest; hover just promotes it to the
                        // row's normal secondary color for a clearer target.
                        Button(action: onDeleteRequested) {
                            Image(systemName: "trash")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isHovering ? .secondary : .tertiary)
                        .help("Delete Session…")
                        .accessibilityLabel("Delete Session")
                        .accessibilityIdentifier("SessionRow-\(session.title)-DeleteButton")
                    }
                }
                metadataLine
            }
            .padding(.top, 1)
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { isHovering = $0 }
        .listRowBackground(rowBackground)
        // Without this, SwiftUI's automatic accessibility inference
        // collapses the whole row into a single element representing just
        // the title text, silently dropping the delete button (and
        // everything else) from the accessibility tree — not hidden, just
        // never exposed as a queryable child. `.contain` keeps the row
        // itself addressable by the identifier the call site assigns, while
        // still exposing each interactive child individually.
        .accessibilityElement(children: .contain)
    }

    private var providerTile: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(FlotillaColors.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(FlotillaColors.separator.opacity(0.6), lineWidth: 0.5)
                }
                .overlay {
                    ProviderLogo(agent: session.agent)
                        .padding(5)
                }
            statusBeacon
                .offset(x: 4, y: 4)
        }
        .frame(width: 28, height: 28)
        // The metadata line states the status in words, so the beacon is
        // hidden from VoiceOver to keep the row a single coherent read.
        .accessibilityHidden(true)
    }

    /// The pulse is drawn at a fixed size and animated with `scaleEffect`
    /// inside a fixed-size container. Animating the ring's `frame` instead
    /// would resize the beacon's own bounds every frame, and since it is
    /// bottom-trailing aligned against the provider tile, the dot itself
    /// visibly crawled around while a session was working.
    private var statusBeacon: some View {
        ZStack {
            Circle()
                .stroke(statusColor, lineWidth: 1)
                .frame(width: 8, height: 8)
                .scaleEffect(beaconPulses ? 1.9 : 0.9)
                .opacity(beaconPulses ? 0 : 0.55)
                .opacity(isPulsing ? 1 : 0)
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(FlotillaColors.sidebar, lineWidth: 1.5))
        }
        .frame(width: 16, height: 16)
        .animation(pulseAnimation, value: beaconPulses)
        .onAppear { beaconPulses = isPulsing }
        .onChange(of: isPulsing) { _, pulsing in beaconPulses = pulsing }
    }

    /// `nil` when the beacon is settling back to rest, so switching out of
    /// `.working` stops the repeating animation instead of leaving a
    /// `repeatForever` transaction attached to the next state change.
    private var pulseAnimation: Animation? {
        beaconPulses ? .easeOut(duration: 1.1).repeatForever(autoreverses: false) : nil
    }

    private var metadataLine: some View {
        HStack(spacing: 5) {
            statusWord
            Text("·")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let branch = session.worktree?.branchName {
                GitBranchIcon(size: 9)
                Text(branch)
                    .font(.caption2.monospaced())
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            } else {
                Text(session.agent.displayName)
                    .font(.caption2)
            }
            if let diffStatStore {
                Spacer(minLength: 2)
                SessionDiffStatView(session: session, diffStatStore: diffStatStore)
            }
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// The status word reserves the width of the *longest* status, so the
    /// branch name beside it holds still as a session moves between states.
    /// "Waiting for Input" is more than twice the width of "Idle", and
    /// letting the word size itself shoved the rest of the line sideways on
    /// every transition — the sidebar's most visible source of jitter.
    private var statusWord: some View {
        ZStack(alignment: .leading) {
            ForEach(StatusPresentation.attentionOrder, id: \.self) { status in
                Text(StatusPresentation.label(for: status)).hidden()
            }
            Text(StatusPresentation.label(for: session.status, waitingReason: session.waitingReason))
                .foregroundStyle(statusColor)
        }
        .font(.caption2.weight(.semibold))
        .fixedSize()
        .animation(.easeInOut(duration: 0.18), value: session.status)
        .animation(.easeInOut(duration: 0.18), value: session.waitingReason)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(backgroundFill)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(FlotillaColors.separator, lineWidth: 0.5)
                }
            }
    }

    private var backgroundFill: Color {
        if isSelected { return FlotillaColors.surfaceElevated }
        // A whole-row attention wash for sessions that need input — signal
        // carried by shape and area, not by a colored edge stripe.
        if needsInput { return Color.orange.opacity(isHovering ? 0.13 : 0.08) }
        return isHovering ? Color.white.opacity(0.035) : .clear
    }

    /// Compact, monospace-friendly recency: "now", "42m", "3h", "9d".
    static func compactTimestamp(for date: Date, relativeTo now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<90: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }
}
