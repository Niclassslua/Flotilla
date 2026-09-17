import AppKit
import CompanionKit
import CoreImage.CIFilterBuiltins
import DesignSystem
import SwiftUI

/// Settings ▸ iPhone Companion: turn the link on, pair a phone, see where the
/// Mac is reachable, and remove paired phones.
struct CompanionSettingsPane: View {
    @Environment(CompanionHost.self) private var host
    @State private var isShowingPairing = false
    @State private var pendingRevoke: PairedDevice?
    @State private var presentedPairing: CompanionHost.PendingPairing?

    var body: some View {
        @Bindable var host = host
        Form {
            Section {
                Toggle("Allow iPhone companion", isOn: $host.isEnabled)
                    .accessibilityIdentifier("CompanionSettings.Enabled")
                LabeledContent("Status") { statusLabel }
                if let error = host.setupError {
                    Text(error).foregroundStyle(FlotillaColors.danger).font(.callout)
                }
            } footer: {
                Text("While Flotilla runs, paired iPhones can watch and control your sessions over your local network or Tailscale. Everything is end-to-end encrypted.")
            }

            Section {
                Button("Pair iPhone…") {
                    host.beginPairing()
                    isShowingPairing = true
                }
                .disabled(!isListening)
                .accessibilityIdentifier("CompanionSettings.Pair")
            } header: {
                Text("Pairing")
            } footer: {
                Text("Open Flotilla on your iPhone and scan the code. Each code works once and expires after five minutes.")
            }

            Section("Reachable at") {
                addressRows
            }

            Section("Paired iPhones") {
                if host.devices.isEmpty {
                    Text("No iPhones paired yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(host.devices) { device in
                        deviceRow(device)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingPairing, onDismiss: { host.cancelPairing() }) {
            CompanionPairingSheet()
                .environment(host)
        }
        .sheet(item: $presentedPairing) { pending in
            CompanionPairingConfirmationSheet(pairing: pending) {
                host.approvePairing(pending.id)
            } onReject: {
                host.rejectPairing(pending.id)
            }
            .environment(host)
        }
        .confirmationDialog(
            pendingRevoke.map { "Remove “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { pendingRevoke != nil }, set: {
                if !$0 {
                    pendingRevoke = nil
                }
            }),
            presenting: pendingRevoke
        ) { device in
            Button("Remove", role: .destructive) { host.revoke(device.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The iPhone is disconnected and can't reconnect until it's paired again.")
        }
        .onAppear {
            host.refreshAddresses()
            presentedPairing = host.pendingPairings.first
        }
        .onChange(of: host.pendingPairings) { _, pending in
            if presentedPairing == nil {
                presentedPairing = pending.first
            }
        }
    }

    private var isListening: Bool {
        if case .listening = host.status {
            return true
        }
        return false
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch host.status {
        case .off:
            Text("Off").foregroundStyle(.secondary)
        case .starting:
            Text("Starting…").foregroundStyle(.secondary)
        case let .listening(port):
            Label("Listening on port \(String(port)) · \(host.connectedDeviceIDs.count) connected", systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(FlotillaColors.statusWorking)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(FlotillaColors.danger)
        }
    }

    @ViewBuilder
    private var addressRows: some View {
        let lan = host.addresses.filter { $0.path == .lan }
        let tailnet = host.addresses.filter { $0.path == .tailscale }
        LabeledContent("Local network") {
            Text(lan.isEmpty ? "Not connected" : lan.map(\.address).joined(separator: ", "))
                .foregroundStyle(lan.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
        }
        LabeledContent("Tailscale") {
            VStack(alignment: .trailing, spacing: 2) {
                if tailnet.isEmpty {
                    Text("Not connected").foregroundStyle(.secondary)
                } else {
                    Text(tailnet.map(\.address).joined(separator: ", ")).textSelection(.enabled)
                    if let name = host.tailscaleDNSName {
                        Text(name).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func deviceRow(_ device: PairedDevice) -> some View {
        HStack {
            Image(systemName: "iphone")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                Text(deviceSubtitle(device))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if host.connectedDeviceIDs.contains(device.id) {
                Text("Connected")
                    .font(.caption)
                    .foregroundStyle(FlotillaColors.statusWorking)
            }
            Button("Remove…") { pendingRevoke = device }
                .buttonStyle(.borderless)
        }
    }

    private func deviceSubtitle(_ device: PairedDevice) -> String {
        let paired = "Paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))"
        guard let lastSeen = device.lastSeen else { return paired }
        return paired + " · last seen \(lastSeen.formatted(.relative(presentation: .named)))"
    }
}

/// A deliberate approval step for a new device. The QR code proves possession
/// of the short-lived secret; this Mac-side decision is what makes the device
/// trusted and allows it to receive the fleet.
private struct CompanionPairingConfirmationSheet: View {
    let pairing: CompanionHost.PendingPairing
    let onApprove: () -> Void
    let onReject: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(FlotillaColors.accent.opacity(0.14))
                    .frame(width: 92, height: 92)
                Image(systemName: "iphone.gen3.and.arrow.forward")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(FlotillaColors.accent)
            }
            .padding(.top, 28)

            Text("Approve iPhone pairing?")
                .font(.title2.weight(.bold))
                .padding(.top, 20)
            Text("An iPhone just used your pairing code to request access to this Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pairing.deviceName)
                            .fontWeight(.semibold)
                        Text("Device name")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "iphone")
                        .foregroundStyle(FlotillaColors.accent)
                }
                Divider()
                Label("The connection is encrypted", systemImage: "lock.fill")
                Label("Only approve a device you recognize", systemImage: "checkmark.shield")
            }
            .font(.callout)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous)
                    .stroke(FlotillaColors.separator, lineWidth: 1)
            }
            .padding(.top, 24)

            HStack(spacing: 10) {
                Button("Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Approve iPhone", systemImage: "checkmark.circle.fill") {
                    onApprove()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(FlotillaColors.accent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("CompanionPairing.Approve")
            }
            .controlSize(.large)
            .padding(.top, 24)

            Button("Reject and disconnect") {
                onReject()
                dismiss()
            }
            .buttonStyle(.link)
            .foregroundStyle(FlotillaColors.danger)
            .padding(.top, 12)
            .accessibilityIdentifier("CompanionPairing.Reject")
        }
        .padding(28)
        .frame(width: 430)
    }
}

/// The QR code, the copyable link, and a countdown. Closes itself once the
/// phone pairs.
struct CompanionPairingSheet: View {
    @Environment(CompanionHost.self) private var host
    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair an iPhone")
                .font(.title2.weight(.semibold))
            if let pairing = host.pairing {
                Text("In Flotilla on your iPhone, tap **Pair a Mac** and scan this code.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if let image = QRCode.image(for: pairing.link) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 260, height: 260)
                        .padding(12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Pairing QR code")
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(pairing.payload.expiresAt.timeIntervalSince(context.date)))
                    Text("Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                pathSummary(pairing.payload)
                HStack {
                    Button(didCopy ? "Copied" : "Copy Pairing Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pairing.link, forType: .string)
                        didCopy = true
                    }
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                ContentUnavailableView(
                    "No Active Code",
                    systemImage: "qrcode",
                    description: Text("The code expired or an iPhone just paired.")
                )
                HStack {
                    Button("Show New Code") { host.beginPairing() }
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func pathSummary(_ payload: PairingPayload) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                payload.hasLANCandidate ? "Local network: included" : "Local network: this Mac has no LAN address",
                systemImage: payload.hasLANCandidate ? "checkmark.circle.fill" : "xmark.circle"
            )
            Label(
                payload.hasTailscaleCandidate ? "Tailscale: included" : "Tailscale: not connected on this Mac",
                systemImage: payload.hasTailscaleCandidate ? "checkmark.circle.fill" : "minus.circle"
            )
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

enum QRCode {
    static func image(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
