import SwiftUI
import AVFoundation
import DesignSystem
import CompanionKit

/// Pairs this iPhone with a Mac: scan or paste the code, watch each network
/// path being tried, and land in that Mac's fleet — or see exactly why not.
struct PairMacView: View {
    /// A link to start with (opened from Camera, or `-pairingLink`).
    var initialLink: String?
    var onPaired: (MacHost.ID) -> Void = { _ in }

    @Environment(CompanionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    enum Step: Equatable {
        case intro
        case scanning
        case pasting
        case connecting(PairingPayload)
        case paired(macID: String, name: String)
        case failed(ConnectionDiagnosis, retry: PairingPayload?)
    }

    @State private var step: Step = .intro
    @State private var linkText = ""
    @State private var attempts: [ConnectTarget: AttemptStatus] = [:]

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .intro: intro
                case .scanning: scanner
                case .pasting: pasteForm
                case .connecting(let payload): connecting(payload)
                case .paired(_, let name): paired(name)
                case .failed(let diagnosis, let retry): ConnectionDiagnosisView(diagnosis: diagnosis, attempts: attempts, retry: retry.map { payload in { start(payload) } }, startOver: { step = .intro })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FlotillaColors.canvas)
            .navigationTitle("Pair a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .paired = step {} else {
                        Button("Cancel", systemImage: "xmark") { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(isConnecting)
        .onAppear {
            if let initialLink { handle(link: initialLink) }
        }
    }

    private var isConnecting: Bool {
        if case .connecting = step { return true }
        return false
    }

    // MARK: Steps

    private var intro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 52))
                    .foregroundStyle(FlotillaColors.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                Text("Control Flotilla on your Mac from this iPhone.")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 14) {
                    instruction(1, "On your Mac, open **Flotilla ▸ Settings ▸ iPhone Companion**.")
                    instruction(2, "Turn on **Allow iPhone companion** and click **Pair iPhone…**")
                    instruction(3, "Scan the code shown on the Mac.")
                }
                .padding(16)
                .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous))

                Label("Works on the same Wi-Fi, or from anywhere when both devices use Tailscale.", systemImage: "network")
                    .font(.footnote)
                    .foregroundStyle(FlotillaColors.textSecondary)

                VStack(spacing: 10) {
                    Button {
                        step = .scanning
                    } label: {
                        Label("Scan Code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(FlotillaColors.accent)
                    .accessibilityIdentifier("Pairing.Scan")

                    Button {
                        linkText = UIPasteboard.general.hasStrings ? (UIPasteboard.general.string ?? "") : ""
                        if !linkText.hasPrefix("\(PairingPayload.scheme)://") { linkText = "" }
                        step = .pasting
                    } label: {
                        Label("Paste Pairing Link", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("Pairing.Paste")
                }
                .controlSize(.large)
            }
            .padding(20)
        }
    }

    private func instruction(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.footnote.weight(.bold).monospacedDigit())
                .frame(width: 22, height: 22)
                .background(FlotillaColors.surfaceElevated, in: Circle())
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var scanner: some View {
        QRScannerView { code in
            handle(link: code)
        } onUnavailable: {
            step = .pasting
        }
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .bottom) {
            Button("Paste Link Instead") { step = .pasting }
                .buttonStyle(.glass)
                .padding(.bottom, 32)
        }
    }

    private var pasteForm: some View {
        Form {
            Section {
                TextField("flotilla://pair?p=…", text: $linkText, axis: .vertical)
                    .lineLimit(3...8)
                    .font(.footnote.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("Pairing.LinkField")
            } footer: {
                Text("On the Mac, click **Copy Pairing Link** under the code, then paste it here — for example through Universal Clipboard.")
            }
            Section {
                Button("Pair") { handle(link: linkText) }
                    .disabled(linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("Pairing.Submit")
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func connecting(_ payload: PairingPayload) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                ProgressView()
                    .controlSize(.large)
                    .padding(.top, 24)
                Text("Connecting to \(payload.macName)…")
                    .font(.title3.weight(.semibold))
                AttemptList(targets: targets(for: payload), attempts: attempts)
            }
            .padding(20)
        }
    }

    private func paired(_ name: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(FlotillaColors.success)
                .symbolEffect(.bounce, value: name)
            Text("Paired with \(name)")
                .font(.title2.weight(.semibold))
            if let path = attempts.first(where: { $0.value == .connected })?.key {
                Text("Connected over \(path.path.displayName) · \(path.label)")
                    .font(.subheadline)
                    .foregroundStyle(FlotillaColors.textSecondary)
            }
            Spacer()
            Button {
                if case .paired(let macID, _) = step {
                    dismiss()
                    onPaired(macID)
                }
            } label: {
                Text("Show Sessions").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(FlotillaColors.accent)
            .controlSize(.large)
            .padding(20)
            .accessibilityIdentifier("Pairing.Done")
        }
        .sensoryFeedback(.success, trigger: name)
    }

    // MARK: Flow

    private func handle(link: String) {
        do {
            start(try PairingPayload(link: link))
        } catch {
            step = .failed(ConnectionDiagnosis.diagnose(error: error, attempts: [:], offeredPaths: [], phoneHasTailnet: NetworkInterfaces.hasTailnetAddress, localNetworkDenied: false), retry: nil)
        }
    }

    private func start(_ payload: PairingPayload) {
        attempts = [:]
        step = .connecting(payload)
        Task {
            do {
                let macID = try await store.pair(with: payload) { target, status in
                    attempts[target] = status
                }
                step = .paired(macID: macID, name: store.mac(macID)?.name ?? payload.macName)
            } catch let failure as PairingFailure {
                // Only a transport failure leaves the secret unused, so only
                // then is retrying the same code worthwhile.
                let canRetry = failure.diagnosis.headline == .unreachable || failure.diagnosis.headline == .localNetworkDenied
                step = .failed(failure.diagnosis, retry: canRetry && !payload.isExpired() ? payload : nil)
            } catch {
                step = .failed(ConnectionDiagnosis.diagnose(error: error, attempts: attempts, offeredPaths: Set(payload.candidates.map(\.kind.path)), phoneHasTailnet: NetworkInterfaces.hasTailnetAddress, localNetworkDenied: false), retry: nil)
            }
        }
    }

    private func targets(for payload: PairingPayload) -> [ConnectTarget] {
        let known = payload.candidates.compactMap(ConnectTarget.init)
        return known + attempts.keys.filter { !known.contains($0) }
    }
}

/// Each address being tried, grouped by path.
struct AttemptList: View {
    let targets: [ConnectTarget]
    let attempts: [ConnectTarget: AttemptStatus]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(NetworkPath.allCases, id: \.self) { path in
                let pathTargets = targets.filter { $0.path == path }
                VStack(alignment: .leading, spacing: 6) {
                    Label(path.displayName, systemImage: path == .lan ? "wifi" : "point.3.filled.connected.trianglepath.dotted")
                        .font(.subheadline.weight(.semibold))
                    if pathTargets.isEmpty {
                        Text("No address for this path")
                            .font(.footnote)
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }
                    ForEach(pathTargets, id: \.self) { target in
                        HStack {
                            Text(target.label)
                                .font(.footnote.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            statusView(attempts[target])
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private func statusView(_ status: AttemptStatus?) -> some View {
        switch status {
        case nil, .connecting?:
            ProgressView().controlSize(.mini)
        case .connected?:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(FlotillaColors.success)
        case .failed(let error)?:
            Label(ConnectionDiagnosis.describe(error), systemImage: "xmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(FlotillaColors.danger)
        case .abandoned?:
            Text("not needed").font(.caption).foregroundStyle(FlotillaColors.textTertiary)
        }
    }
}

/// Why pairing or connecting failed, with per-path advice.
struct ConnectionDiagnosisView: View {
    let diagnosis: ConnectionDiagnosis
    var attempts: [ConnectTarget: AttemptStatus] = [:]
    var retry: (() -> Void)?
    var startOver: (() -> Void)?

    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(FlotillaColors.warning)
                    .frame(maxWidth: .infinity)
                Text(diagnosis.title)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("Pairing.FailureTitle")
                Text(diagnosis.message)
                    .font(.subheadline)
                    .foregroundStyle(FlotillaColors.textSecondary)

                if showsPaths {
                    ForEach(diagnosis.paths) { report in
                        PathReportCard(report: report, advice: diagnosis.advice(for: report))
                    }
                }

                VStack(spacing: 10) {
                    if diagnosis.localNetworkDenied {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        } label: {
                            Label("Open Settings", systemImage: "gear").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                    if let retry {
                        Button(action: retry) {
                            Text("Try Again").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(FlotillaColors.accent)
                    }
                    if let startOver {
                        Button(action: startOver) {
                            Text("Scan a New Code").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .controlSize(.large)
            }
            .padding(20)
        }
    }

    private var showsPaths: Bool {
        switch diagnosis.headline {
        case .unreachable, .localNetworkDenied: true
        default: false
        }
    }
}

private struct PathReportCard: View {
    let report: ConnectionDiagnosis.PathReport
    let advice: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(report.path.displayName, systemImage: report.path == .lan ? "wifi" : "point.3.filled.connected.trianglepath.dotted")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(outcomeText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(outcomeColor)
            }
            if case .failed(let failures) = report.outcome {
                ForEach(failures.sorted { $0.key < $1.key }, id: \.key) { address, reason in
                    Text("\(address) — \(reason)")
                        .font(.caption.monospaced())
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
            }
            ForEach(advice, id: \.self) { line in
                Label(line, systemImage: "arrow.turn.down.right")
                    .font(.footnote)
                    .foregroundStyle(FlotillaColors.textSecondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
    }

    private var outcomeText: String {
        switch report.outcome {
        case .notOffered: "Not available"
        case .succeeded: "Reached"
        case .failed: "Failed"
        case .notNeeded: "Not tried"
        }
    }

    private var outcomeColor: Color {
        switch report.outcome {
        case .succeeded: FlotillaColors.success
        case .failed: FlotillaColors.danger
        case .notOffered, .notNeeded: FlotillaColors.textTertiary
        }
    }
}

/// Camera QR scanner. Falls back to `onUnavailable` without a camera or
/// permission (the simulator has neither).
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onUnavailable: () -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        controller.onUnavailable = onUnavailable
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
        var onCode: (String) -> Void = { _ in }
        var onUnavailable: () -> Void = {}
        private let session = AVCaptureSession()
        private var didReport = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                configure()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async { granted ? self.configure() : self.onUnavailable() }
                }
            default:
                onUnavailable()
            }
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                onUnavailable()
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { onUnavailable(); return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
            let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            view.layer.sublayers?.first { $0 is AVCaptureVideoPreviewLayer }?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !didReport,
                  let code = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
                  code.hasPrefix("\(PairingPayload.scheme)://") else { return }
            didReport = true
            onCode(code)
        }
    }
}
