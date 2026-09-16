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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProviderLogo(agent: session.agent)
                .frame(width: 22, height: 22)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(session.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .font(.caption2)
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .monospacedDigit()
                }

                HStack(spacing: 5) {
                    StatusDot(status: session.status)
                    Text(StatusPresentation.label(for: session.status, waitingReason: session.waitingReason))
                        .foregroundStyle(StatusPresentation.color(for: session.status))
                    Text("·").foregroundStyle(FlotillaColors.textTertiary)
                    Text(session.branch.map { "\(projectName) / \($0)" } ?? projectName)
                        .foregroundStyle(FlotillaColors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
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

    var body: some View {
        Circle()
            .fill(StatusPresentation.color(for: status))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Sticky notice over a Mac's cached, read-only content.
struct UnreachableBanner: View {
    let mac: MacHost
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
        case .connecting: "Connecting to \(mac.name)…"
        case .needsRepairing(let reason): reason.message
        default: "\(mac.name) is unreachable · last seen \(mac.lastSeen.formatted(date: .omitted, time: .shortened))"
        }
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
