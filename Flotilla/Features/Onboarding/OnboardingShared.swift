import AppKit
import DesignSystem
import SessionKit
import SettingsKit
import SwiftUI
import UserNotifications

// MARK: - Draft

/// Agent and project choices stay in the draft until completion. Notification
/// permission and iPhone pairing happen when the user explicitly requests them.
@Observable
@MainActor
final class OnboardingDraft {
    let detectedAgents: Set<AgentKind>
    let missingTools: Set<OnboardingTool>
    var enabledAgents: Set<AgentKind>
    private(set) var notificationsEnabled = false
    /// macOS has a "no" on file, so only System Settings can turn them on.
    private(set) var notificationsDenied = false
    private var didChangeNotifications = false
    private var notificationDeliveryEnabled = true
    var projectURL: URL?

    @ObservationIgnored private let requestNotificationAuthorization: @MainActor () async -> Bool

    init(
        detectedAgents: Set<AgentKind>,
        missingTools: Set<OnboardingTool>,
        enabledAgents: Set<AgentKind>? = nil,
        requestNotificationAuthorization: @escaping @MainActor () async -> Bool = OnboardingDraft.requestSystemAuthorization
    ) {
        self.detectedAgents = detectedAgents
        self.missingTools = missingTools
        self.enabledAgents = enabledAgents ?? (detectedAgents.isEmpty ? [.claudeCode] : detectedAgents)
        self.requestNotificationAuthorization = requestNotificationAuthorization
    }

    /// Starts from what Flotilla detected — or, when the user chose agents
    /// before (onboarding reopened from the Help menu), from that choice.
    convenience init(
        startupCheck: StartupCheckViewModel,
        settings: AppSettings,
        requestNotificationAuthorization: @escaping @MainActor () async -> Bool = OnboardingDraft.requestSystemAuthorization
    ) {
        let missing = Set(startupCheck.missingRequiredTools + startupCheck.missingOptionalTools)
        let chosen = settings.sessionDefaults.hasChosenAgents ? Set(settings.sessionDefaults.enabledAgents) : nil
        self.init(
            detectedAgents: Set(AgentKind.allCases).subtracting(startupCheck.missingAgents),
            missingTools: Set(OnboardingTool.allCases.filter { missing.contains($0.rawValue) }),
            enabledAgents: chosen,
            requestNotificationAuthorization: requestNotificationAuthorization
        )
        notificationDeliveryEnabled = settings.notifications.delivery != .never
    }

    static func preview() -> OnboardingDraft {
        OnboardingDraft(detectedAgents: [.claudeCode, .codexCLI], missingTools: [.gh], requestNotificationAuthorization: { true })
    }

    static func requestSystemAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Catalogue order, so every layout lists the crew the same way.
    var orderedEnabledAgents: [AgentKind] {
        AgentKind.allCases.filter { enabledAgents.contains($0) }
    }

    func isEnabled(_ agent: AgentKind) -> Bool {
        enabledAgents.contains(agent)
    }

    /// Keeps at least one agent on — a fleet with no crew can't launch anything.
    func toggle(_ agent: AgentKind) {
        if enabledAgents.contains(agent) {
            guard enabledAgents.count > 1 else { return }
            enabledAgents.remove(agent)
        } else {
            enabledAgents.insert(agent)
        }
    }

    /// Mirrors what macOS already allows, so a reopened onboarding starts
    /// with the switch where the user left it.
    func loadNotificationState() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard !didChangeNotifications else { return }
        notificationsEnabled = notificationDeliveryEnabled && (status == .authorized || status == .provisional)
        notificationsDenied = status == .denied
    }

    /// Turning the switch on asks macOS right away — in context, where the
    /// user can see why — and the switch follows the answer.
    func setNotificationsEnabled(_ isOn: Bool) async {
        didChangeNotifications = true
        guard isOn else {
            notificationsEnabled = false
            return
        }
        notificationsEnabled = true
        let granted = await requestNotificationAuthorization()
        notificationsEnabled = granted
        notificationsDenied = !granted
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Choose a git repository for your first session."
        if panel.runModal() == .OK {
            projectURL = panel.url
        }
    }

    /// Writes the choices into settings and imports the project. Returns the
    /// project's ID so the launcher can open in it.
    func apply(to settings: inout AppSettings, store: AppStore) -> UUID? {
        settings.sessionDefaults.setEnabledAgents(enabledAgents)
        if didChangeNotifications {
            if !notificationsEnabled {
                settings.notifications.delivery = .never
            } else if settings.notifications.delivery == .never {
                settings.notifications.delivery = .always
            }
        }
        guard let projectURL else { return nil }
        store.addProject(at: projectURL)
        let path = projectURL.standardizedFileURL.path
        return store.projects.first { $0.rootPath.standardizedFileURL.path == path }?.id
    }
}

enum OnboardingTool: String, CaseIterable, Identifiable, Sendable {
    case git, tmux, gh

    var id: String { rawValue }

    var installCommand: String {
        switch self {
        case .git: "xcode-select --install"
        case .tmux: "brew install tmux"
        case .gh: "brew install gh"
        }
    }
}

extension AgentKind {
    var onboardingTagline: String {
        switch self {
        case .claudeCode: "Anthropic's coding agent"
        case .codexCLI: "OpenAI's coding agent"
        case .openCode: "Open source, bring any model"
        case .antigravity: "Google's coding agent"
        case .cursorAgent: "Cursor's agent, in the terminal"
        }
    }

    var installGuideURL: URL {
        switch self {
        case .claudeCode: URL(string: "https://docs.anthropic.com/en/docs/claude-code/setup")!
        case .codexCLI: URL(string: "https://github.com/openai/codex")!
        case .openCode: URL(string: "https://opencode.ai/docs")!
        case .antigravity: URL(string: "https://antigravity.google")!
        case .cursorAgent: URL(string: "https://cursor.com/cli")!
        }
    }
}

// MARK: - Building blocks

/// The System Settings-style glyph tile: a white symbol on a coloured square.
struct OnboardingSymbolTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Title and subtitle used at the top of a step.
struct OnboardingHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: FlotillaSpacing.small) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(FlotillaColors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(FlotillaTypography.body)
                .foregroundStyle(FlotillaColors.textSecondary)
                .multilineTextAlignment(.center)
        }
    }
}

/// Page dots that double as a jump control.
struct OnboardingPageDots: View {
    let count: Int
    @Binding var index: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { page in
                Button {
                    index = page
                } label: {
                    Capsule()
                        .fill(page == index ? FlotillaColors.textPrimary : FlotillaColors.textTertiary.opacity(0.5))
                        .frame(width: page == index ? 18 : 7, height: 7)
                        .contentShape(Rectangle().inset(by: -6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Page \(page + 1) of \(count)")
                .accessibilityAddTraits(page == index ? .isSelected : [])
            }
        }
        .animation(.snappy, value: index)
    }
}

// MARK: - Setup options

/// Notifications, first project, and iPhone pairing as a grouped settings list.
struct SetupOptionsList: View {
    let draft: OnboardingDraft

    @Environment(CompanionHost.self) private var companionHost
    @State private var isPairingPresented = false

    var body: some View {
        VStack(spacing: 0) {
            SetupOptionRow(
                symbol: "bell.badge.fill",
                color: .red,
                title: "Notifications",
                detail: draft.notificationsDenied
                    ? "Turned off in System Settings ▸ Notifications."
                    : "Get a heads-up when an agent is waiting for you."
            ) {
                Toggle("Notifications", isOn: Binding(
                    get: { draft.notificationsEnabled },
                    set: { isOn in Task { await draft.setNotificationsEnabled(isOn) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityIdentifier(AXID.onboardingNotificationsToggle.rawValue)
            }
            Divider().padding(.leading, 56)
            SetupOptionRow(
                symbol: "folder.fill",
                color: .blue,
                title: "First Project",
                detail: draft.projectURL.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Pick a git repository to start in."
            ) {
                Button(draft.projectURL == nil ? "Choose…" : "Change…") { draft.chooseProject() }
                    .accessibilityIdentifier(AXID.onboardingChooseProjectButton.rawValue)
            }
            Divider().padding(.leading, 56)
            SetupOptionRow(
                symbol: "iphone",
                color: .gray,
                title: "iPhone Companion",
                detail: companionHost.devices.isEmpty
                    ? "Approve requests from anywhere. Optional."
                    : "Paired with \(companionHost.devices.map(\.name).formatted(.list(type: .and)))."
            ) {
                Button(companionHost.devices.isEmpty ? "Pair…" : "Pair Another…") { beginPairing() }
            }
        }
        .flotillaPanel()
        .sheet(isPresented: $isPairingPresented, onDismiss: { companionHost.cancelPairing() }) {
            Group {
                switch companionHost.status {
                case .listening:
                    CompanionPairingSheet()
                        .environment(companionHost)
                        .onAppear { companionHost.beginPairing() }
                case .failed(let message):
                    VStack(spacing: 16) {
                        Text("Couldn’t Start Pairing").font(.headline)
                        Text(message).foregroundStyle(.secondary)
                        Button("Done") { isPairingPresented = false }
                    }
                    .padding(24)
                    .frame(width: 420)
                case .off, .starting:
                    VStack(spacing: 16) {
                        ProgressView("Starting iPhone Companion…")
                        Button("Cancel") { isPairingPresented = false }
                    }
                    .padding(24)
                    .frame(width: 420)
                }
            }
        }
    }

    /// Pairing needs the companion host on; turning it on here is what the
    /// user asked for by pressing Pair.
    private func beginPairing() {
        if !companionHost.isEnabled {
            companionHost.isEnabled = true
        }
        isPairingPresented = true
    }


}

private struct SetupOptionRow<Accessory: View>: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            OnboardingSymbolTile(symbol: symbol, color: color, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(FlotillaTypography.body.weight(.medium))
                    .foregroundStyle(FlotillaColors.textPrimary)
                Text(detail)
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            accessory()
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, 10)
    }
}
