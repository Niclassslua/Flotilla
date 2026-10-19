import SwiftUI
import DesignSystem

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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(FlotillaColors.warning.opacity(0.18))
                        .frame(width: 36, height: 36)
                    Image(systemName: iconName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FlotillaColors.warning)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FlotillaColors.textPrimary)
                    Text(subhead)
                        .font(.caption)
                        .foregroundStyle(FlotillaColors.textSecondary)
                }
                Spacer(minLength: 0)
            }

            Text("Commands, new sessions, and live updates are paused. You're seeing the fleet as of \(asOfPhrase).")
                .font(.caption)
                .foregroundStyle(FlotillaColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if needsRepair {
                    Button("Pair Again") { isPairing = true }
                        .companionGlassButtonStyle(prominent: true)
                        .controlSize(.small)
                } else {
                    Button("Try Again") { store.reconnect(mac.id) }
                        .companionGlassButtonStyle(prominent: true)
                        .controlSize(.small)
                        .accessibilityIdentifier("UnreachableBanner.ReconnectNow")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FlotillaColors.warningSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(FlotillaColors.warning.opacity(0.35), lineWidth: 1)
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityIdentifier("UnreachableBanner")
        .sheet(isPresented: $isPairing) {
            PairMacView { macID in store.path = [.fleet(macID)] }
        }
    }

    private var needsRepair: Bool {
        if case .needsRepairing = mac.connection { return true }
        return false
    }

    private var headline: String {
        switch mac.connection {
        case .needsRepairing: "Pairing needs attention"
        default: "Lost connection to \(mac.name)"
        }
    }

    private var subhead: String {
        switch mac.connection {
        case .needsRepairing(let reason): reason.message
        default: "Last seen \(mac.lastSeen.formatted(.relative(presentation: .named)))"
        }
    }

    private var asOfPhrase: String {
        guard let asOf else { return "an unknown time" }
        return asOf.formatted(date: .omitted, time: .shortened)
    }

    private var iconName: String {
        switch mac.connection {
        case .needsRepairing: "exclamationmark.shield"
        default: "wifi.exclamationmark"
        }
    }
}
