import SwiftUI
import DesignSystem

/// Compact status capsule over a Mac's cached, read-only content. The reasons
/// and the retry live in a sheet it opens. When the link comes back it turns
/// into a brief confirmation before leaving.
struct UnreachableBanner: View {
    let mac: MacHost
    /// When the content shown beneath this banner was actually received —
    /// `nil` means a legacy cache with no such record, which reads as
    /// unknown rather than guessing "now".
    var asOf: Date? = nil
    @Environment(CompanionStore.self) private var store
    @State private var isShowingDetails = false
    @State private var isPairing = false
    @State private var tryAgainTaps = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { isShowingDetails = true } label: {
            HStack(spacing: 8) {
                statusGlyph
                    .frame(width: 20, height: 20)
                // One view per message: the old one slides out as the new one
                // slides in, so two lines of text never share the same spot.
                HStack(spacing: 6) {
                    Text(headline)
                        .fontWeight(.semibold)
                        .foregroundStyle(FlotillaColors.textPrimary)
                    if let subhead {
                        Text(subhead)
                            .foregroundStyle(FlotillaColors.textSecondary)
                            .lineLimit(1)
                    }
                }
                .id("\(headline)|\(subhead ?? "")")
                .transition(reduceMotion ? .opacity : .push(from: .bottom))
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .opacity(mac.isReachable ? 0 : 1)
                    .accessibilityHidden(true)
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!mac.isReachable)
        .companionGlassEffect(interactive: true, in: Capsule())
        .animation(reduceMotion ? nil : .snappy, value: mac.connection)
        .accessibilityHint(mac.isReachable ? "" : "Shows connection details")
        .sensoryFeedback(trigger: mac.isReachable) { _, connected in connected ? .success : nil }
        .onChange(of: mac.isReachable) { _, connected in
            guard connected else { return }
            isShowingDetails = false
            AccessibilityNotification.Announcement("Connected to \(mac.name)").post()
        }
        .accessibilityIdentifier("UnreachableBanner")
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .sheet(isPresented: $isShowingDetails) {
            details
                .presentationDetents([.fraction(0.68), .large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        if mac.isReachable {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(FlotillaColors.success)
                .transition(.scale(scale: 0.3).combined(with: .opacity))
                .accessibilityHidden(true)
        } else if isReconnecting {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: needsRepair ? "exclamationmark.shield" : "wifi.slash")
                .foregroundStyle(FlotillaColors.warning)
                .accessibilityHidden(true)
        }
    }

    private var details: some View {
        NavigationStack {
            List {
                if case .needsRepairing(let reason) = mac.connection {
                    Section {
                        Text(reason.message)
                    }
                } else if let diagnosis {
                    Section {
                        ForEach(diagnosis.paths) { report in
                            if let status = diagnosis.pathStatus(for: report) {
                                pathRow(report, status: status, advice: diagnosis.outageLine(for: report))
                            }
                        }
                    } header: {
                        Text(isReconnecting ? diagnosis.tryingNote : "Retries automatically")
                    }
                }

                Section {
                    LabeledContent("Last seen", value: mac.lastSeen.formatted(date: .omitted, time: .shortened))
                } footer: {
                    Text("Commands, new sessions, and live updates are paused. You're seeing the fleet as of \(asOfPhrase).")
                }
            }
            .navigationTitle(detailsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { detailsAction }
            .sheet(isPresented: $isPairing) {
                PairMacView { macID in store.path = [.fleet(macID)] }
            }
        }
    }

    private func pathRow(_ report: ConnectionDiagnosis.PathReport, status: String, advice: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent {
                Text(status)
            } label: {
                Label(report.path.displayName, systemImage: report.path == .lan ? "wifi" : "point.3.filled.connected.trianglepath.dotted")
            }
            .font(.subheadline)
            if let advice {
                Text(advice)
                    .font(.footnote)
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detailsAction: some View {
        Button {
            if needsRepair {
                isPairing = true
            } else {
                tryAgainTaps += 1
                store.reconnect(mac.id)
            }
        } label: {
            HStack(spacing: 8) {
                if isReconnecting {
                    ProgressView().controlSize(.small)
                }
                Text(actionTitle)
            }
            .frame(maxWidth: .infinity, minHeight: 34)
        }
        .companionGlassButtonStyle(prominent: true)
        .controlSize(.large)
        .disabled(isReconnecting || mac.isReachable)
        .sensoryFeedback(.impact(weight: .medium), trigger: tryAgainTaps)
        .accessibilityIdentifier("UnreachableBanner.ReconnectNow")
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var diagnosis: ConnectionDiagnosis? {
        (store.data as? RemoteCompanionDataSource)?.diagnostics(for: mac.id)?.diagnosis
    }

    private var isReconnecting: Bool {
        mac.connection == .reconnecting
    }

    private var needsRepair: Bool {
        if case .needsRepairing = mac.connection { return true }
        return false
    }

    private var headline: String {
        if mac.isReachable { return "Connected" }
        if needsRepair { return "Pairing needs attention" }
        return isReconnecting ? "Reconnecting…" : "Offline"
    }

    private var subhead: String? {
        if case .connected(let path, _) = mac.connection { return path.displayName }
        guard !needsRepair, !isReconnecting else { return nil }
        return diagnosis?.shortReason ?? "Last seen \(mac.lastSeen.formatted(date: .omitted, time: .shortened))"
    }

    private var detailsTitle: String {
        if mac.isReachable { return "Connected" }
        if needsRepair { return "Pairing Needs Attention" }
        return isReconnecting ? "Reconnecting…" : "Can't Reach \(mac.name)"
    }

    private var actionTitle: String {
        if mac.isReachable { return "Connected" }
        if needsRepair { return "Pair Again" }
        return isReconnecting ? "Reconnecting…" : "Try Again"
    }

    private var asOfPhrase: String {
        guard let asOf else { return "an unknown time" }
        return asOf.formatted(date: .omitted, time: .shortened)
    }
}
