import SwiftUI
import SessionKit
import DesignSystem
import CompanionKit

/// A fleet row: logo, title, status, project / branch, time, and one line of
/// what's happening or what's needed.
struct SessionRowView: View {
    let session: CompanionSession
    let projectName: String
    /// The latest complete line of assistant text, for working rows.
    let latestLine: String?

    private var isWorking: Bool { session.status == .working }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                ProviderLogo(agent: session.agent)
                    .frame(width: 22, height: 22)
                StatusDot(status: session.status, size: 8, isPulsing: isWorking)
                    .background(Circle().fill(FlotillaColors.surface).frame(width: 11, height: 11))
                    .offset(x: 3, y: 3)
            }
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        if isWorking {
                            ElapsedTimer(since: session.updatedAt)
                        } else {
                            Text(session.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                                .font(.caption2)
                                .foregroundStyle(FlotillaColors.textTertiary)
                                .monospacedDigit()
                        }
                    }
                }

                HStack(spacing: 5) {
                    Text(session.branch.map { "\(projectName) / \($0)" } ?? projectName)
                        .foregroundStyle(FlotillaColors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let diffStat = session.diffStat, diffStat.hasChanges {
                        Spacer(minLength: 8)
                        DiffPill(diffStat: diffStat)
                    }
                }
                .font(.caption)

                if let subtitle {
                    Text(subtitle.text)
                        .font(.caption)
                        .foregroundStyle(subtitle.color)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: (text: String, color: Color)? {
        if let failure = session.failure {
            return ("Failed · \(failure)", FlotillaColors.danger)
        }
        if session.status == .crashed, let reason = session.crashReason {
            return (reason, FlotillaColors.danger)
        }
        if session.status == .waitingForInput, let summary = session.attentionSummary {
            return (summary, FlotillaColors.textPrimary)
        }
        if session.status == .working, let latestLine {
            return (latestLine, FlotillaColors.textSecondary)
        }
        return nil
    }
}

struct StatusDot: View {
    let status: SessionStatus?
    var size: CGFloat = 7
    var isPulsing: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let color = StatusPresentation.color(for: status)
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .modifier(PulsingGlow(color: color, size: size, isActive: isPulsing && !reduceMotion))
            .accessibilityHidden(true)
    }
}

/// A soft glow breathes behind the dot while a session is working, so an
/// active row reads as "alive" from a glance.
private struct PulsingGlow: ViewModifier {
    let color: Color
    let size: CGFloat
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.background {
                PhaseAnimator([false, true]) { phase in
                    Circle()
                        .fill(color)
                        .frame(width: size, height: size)
                        .scaleEffect(phase ? 2.4 : 1)
                        .opacity(phase ? 0 : 0.55)
                } animation: { _ in
                    .easeOut(duration: 1.4)
                }
            }
        } else {
            content
        }
    }
}

/// A live "1m 42s" ticker. `since` is the session's
/// `updatedAt` — the closest signal available on the phone to when the
/// current turn started, since `CompanionSession` doesn't carry a separate
/// turn-start timestamp.
private struct ElapsedTimer: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(elapsed(at: context.date))
                .font(.caption2)
                .foregroundStyle(FlotillaColors.textTertiary)
                .monospacedDigit()
        }
    }

    private func elapsed(at now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        let minutes = seconds / 60
        return minutes > 0 ? "\(minutes)m \(seconds % 60)s" : "\(seconds)s"
    }
}

/// Additions/deletions colored the way a diff reads
/// everywhere else, sitting under the timestamp rather than jammed into the
/// status line next to the branch.
private struct DiffPill: View {
    let diffStat: DiffStat

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(diffStat.additions)")
                .foregroundStyle(FlotillaColors.success)
            Text("−\(diffStat.deletions)")
                .foregroundStyle(FlotillaColors.danger)
        }
        .font(.caption2)
        .monospacedDigit()
    }
}

/// Sticky notice over a Mac's cached, read-only content.
struct UnreachableBanner: View {
    let mac: MacHost
    /// When the content shown beneath this banner was actually received —
    /// `nil` means a legacy cache with no such record, which reads as
    /// unknown rather than guessing "now".
    var asOf: Date? = nil
    @Environment(CompanionStore.self) private var store
    @State private var isPairing = false

    var body: some View {
        HStack(spacing: 10) {
            Label {
                Text(text)
            } icon: {
                Image(systemName: icon)
            }
            .lineLimit(2)
            .minimumScaleFactor(0.85)
            if case .needsRepairing = mac.connection, store.supportsPairing {
                Button("Pair Again") { isPairing = true }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            } else if case .unreachable = mac.connection {
                Button("Reconnect Now") { store.reconnect(mac.id) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .accessibilityIdentifier("UnreachableBanner.ReconnectNow")
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(FlotillaColors.textPrimary)
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .glassEffect(.regular.tint(tint.opacity(0.25)), in: Capsule())
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityIdentifier("UnreachableBanner")
        .sheet(isPresented: $isPairing) {
            PairMacView { macID in store.path = [.fleet(macID)] }
        }
    }

    private var text: String {
        switch mac.connection {
        case .connecting: "Connecting to \(mac.name)… showing \(asOfPhrase)"
        case .needsRepairing(let reason): reason.message
        default: "\(mac.name) is unreachable · last seen \(mac.lastSeen.formatted(date: .omitted, time: .shortened)) · showing \(asOfPhrase)"
        }
    }

    /// Never claims cached content is live: an unknown snapshot time says so
    /// plainly instead of falling back to "now".
    private var asOfPhrase: String {
        guard let asOf else { return "content as of an unknown time" }
        return "content as of \(asOf.formatted(date: .omitted, time: .shortened))"
    }

    private var icon: String {
        switch mac.connection {
        case .connecting: "antenna.radiowaves.left.and.right"
        case .needsRepairing: "exclamationmark.shield"
        default: "wifi.slash"
        }
    }

    private var tint: Color {
        if case .needsRepairing = mac.connection { return FlotillaColors.danger }
        return FlotillaColors.warning
    }
}
