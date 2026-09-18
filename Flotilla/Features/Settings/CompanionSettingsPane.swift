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

            Section {
                LabeledContent("Status") { handyStatusLabel }
                switch host.handyStatus {
                case let .connected(model):
                    if let model, !model.isEmpty {
                        LabeledContent("Model") {
                            Text(model)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Check Connection") {
                        Task { await host.checkHandyConnection() }
                    }
                case let .disconnected(reason):
                    Text(reason)
                        .foregroundStyle(FlotillaColors.danger)
                        .font(.callout)
                    HStack {
                        Button("Open Handy") {
                            host.openHandyApp()
                        }
                        Button("Check Again") {
                            Task { await host.checkHandyConnection() }
                        }
                    }
                case .checking:
                    EmptyView()
                }
            } header: {
                Text("Speech to Text (Handy)")
            } footer: {
                Text("Paired iPhones can dictate prompt messages directly into your sessions using Handy on this Mac. Audio streams over the encrypted connection and is transcribed locally by Handy on Apple Silicon. Audio is never persisted or sent to any cloud service.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingPairing, onDismiss: { host.cancelPairing() }) {
            CompanionPairingSheet()
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
            Task { await host.checkHandyConnection() }
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
    private var handyStatusLabel: some View {
        switch host.handyStatus {
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .connected:
            Label("Connected & Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(FlotillaColors.statusWorking)
        case .disconnected:
            Label("Not Connected", systemImage: "xmark.circle.fill")
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

/// The one-use QR code turns into a success receipt as soon as the phone pairs.
struct CompanionPairingSheet: View {
    @Environment(CompanionHost.self) private var host
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didCopy = false
    @State private var celebration = false

    var body: some View {
        Group {
            if let device = host.recentlyPairedDevice {
                pairedReceipt(device)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if let pairing = host.pairing {
                VStack(spacing: 16) {
                    Text("Pair an iPhone")
                        .font(.title2.weight(.semibold))
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
                }
            } else {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "Code Expired",
                        systemImage: "qrcode",
                        description: Text("Show a new code to pair an iPhone.")
                    )
                    HStack {
                        Button("Show New Code") { host.beginPairing() }
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: host.recentlyPairedDevice?.id)
    }

    private func pairedReceipt(_ device: PairedDevice) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .stroke(FlotillaColors.statusWorking.opacity(0.18), lineWidth: 1)
                    .frame(width: 116, height: 116)
                Circle()
                    .fill(FlotillaColors.statusWorking.opacity(0.12))
                    .frame(width: 88, height: 88)
                Image(systemName: "checkmark")
                    .font(.system(size: 37, weight: .medium))
                    .foregroundStyle(FlotillaColors.statusWorking)
                    .symbolEffect(.bounce, value: celebration)
                    .symbolEffectsRemoved(reduceMotion)
            }
            .accessibilityHidden(true)

            Text("iPhone paired")
                .font(.system(size: 25, weight: .semibold))
                .padding(.top, 20)
            Text("\(device.name) is ready to use with this Mac.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 7)

            HStack(spacing: 14) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(FlotillaColors.accent)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Label("End-to-end encrypted", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(FlotillaColors.statusWorking)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.panel))
            .overlay {
                RoundedRectangle(cornerRadius: FlotillaRadius.panel)
                    .stroke(FlotillaColors.separator, lineWidth: 1)
            }
            .padding(.top, 27)

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(FlotillaColors.accent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 24)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CompanionPairing.Success")
        .onAppear {
            if !reduceMotion { celebration.toggle() }
        }
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
