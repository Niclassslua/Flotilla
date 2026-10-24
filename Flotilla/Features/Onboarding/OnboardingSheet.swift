import AppKit
import DesignSystem
import SessionKit
import SettingsKit
import SwiftUI

/// How the user left the onboarding.
enum OnboardingOutcome: Equatable {
    /// Skipped — draft settings and the project are not applied.
    case skipped
    /// Finished — apply the draft and open the launcher.
    case launched
}

/// The first-run onboarding (beta). One stage, four acts: a miniature Flotilla
/// window stays put in the middle of the sheet and changes with every page —
/// it plays use cases, fills with the agents you pick, and finally boots your
/// fleet. The tools that power Flotilla get their own page, apart from agents.
struct OnboardingSheet: View {
    /// Bump to show a redesigned onboarding to everyone once more.
    static let currentVersion = 1

    let draft: OnboardingDraft
    let onFinish: (OnboardingOutcome) -> Void

    @State private var page: Int
    @State private var chapter = 0
    @State private var chapterProgress: CGFloat = 0
    /// Clicking a chapter hands control to the user for good.
    @State private var isTourAutoPlaying = true
    @State private var isLaunching = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = CGSize(width: 760, height: 730)
    private static let pageCount = 4
    private static let chapterDuration: Double = 5
    private static let stageSize = CGSize(width: 640, height: 300)

    static func markExistingUser(settings: inout AppSettings, hasWorkspace: Bool) {
        if settings.onboardingVersion == 0, hasWorkspace {
            settings.onboardingVersion = currentVersion
        }
    }

    /// First launch only, never during UI tests unless a test asks for it —
    /// a sheet over the window would block every other test.
    static func shouldPresent(
        settings: AppSettings,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["UI_TESTING"] == "1" {
            return environment["UI_TESTING_SHOW_ONBOARDING"] == "1" && settings.onboardingVersion < currentVersion
        }
        return settings.onboardingVersion < currentVersion
    }

    init(draft: OnboardingDraft, startPage: Int = 0, onFinish: @escaping (OnboardingOutcome) -> Void) {
        self.draft = draft
        self.onFinish = onFinish
        _page = State(initialValue: startPage)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: 120, alignment: .bottom)
            if page == 2 {
                // No window to hold in place here, so the tools centre in all
                // the room between the header and the bar.
                EngineRoomDiagram(draft: draft)
                    .frame(width: Self.stageSize.width)
                    .frame(maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                stage
                    .frame(width: Self.stageSize.width, height: Self.stageSize.height)
                    .padding(.top, FlotillaSpacing.xLarge)
                controls
                    .padding(.top, FlotillaSpacing.xLarge)
                // Pins the bar to the bottom whatever `controls` holds.
                Spacer(minLength: 0)
            }
            navigationBar
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background { ambientGlow }
        .overlay(alignment: .topTrailing) {
            if page < Self.pageCount - 1 {
                Button("Skip") { onFinish(.skipped) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .keyboardShortcut(.cancelAction)
                    .padding(FlotillaSpacing.large)
                    .accessibilityIdentifier(AXID.onboardingSkipButton.rawValue)
            }
        }
        .overlay(alignment: .topLeading) { betaBadge }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.onboardingSheet.rawValue)
        .task { await draft.loadNotificationState() }
        .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: page)
        .transaction { if reduceMotion { $0.disablesAnimations = true } }
        .task(id: TourTick(page: page, chapter: chapter)) { await playTour() }
    }

    private func go(to target: Int) {
        guard (0..<Self.pageCount).contains(target) else { return }
        page = target
    }

    /// The onboarding is new and still changing — said up front, on every page.
    private var betaBadge: some View {
        Text("Beta")
            .font(FlotillaTypography.caption.weight(.semibold))
            .foregroundStyle(FlotillaColors.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(FlotillaColors.accent.opacity(0.15), in: Capsule())
            .overlay { Capsule().strokeBorder(FlotillaColors.accent.opacity(0.4)) }
            .padding(FlotillaSpacing.large)
            .help("This onboarding is in beta and may change.")
            .accessibilityLabel("Beta: this onboarding may change")
            .accessibilityIdentifier(AXID.onboardingBetaBadge.rawValue)
    }

    // MARK: Header

    private var header: some View {
        OnboardingHeader(title: headerTitle, subtitle: headerSubtitle)
            .frame(maxWidth: 560)
            .id(page)
            .transition(.opacity.combined(with: .offset(y: 6)))
    }

    private var headerTitle: String {
        switch page {
        case 0: "Welcome to Flotilla"
        case 1: "Pick Your Agents"
        case 2: "Under the Hood"
        default: "Ready for Launch"
        }
    }

    private var headerSubtitle: String {
        switch page {
        case 0:
            return "Run a fleet of coding agents side by side — and stay on top of every one."
        case 1:
            return "Flotilla drives the coding agents you already use. Choose the ones you want in your fleet."
        case 2:
            let missing = OnboardingTool.allCases.filter { draft.missingTools.contains($0) }
            if missing.contains(.git) {
                return "Flotilla runs on a few command-line tools. git is required — install it, then come back."
            }
            if missing.isEmpty {
                return "Flotilla runs your agents on proven command-line tools. All systems go."
            }
            let lost = missing.map(\.missingConsequence).formatted(.list(type: .and))
            return "Flotilla runs your agents on proven command-line tools. It works without the missing ones — you'll just miss \(lost)."
        default:
            return "Your fleet is assembled. A few last touches — all optional."
        }
    }

    // MARK: Stage

    private var stage: some View {
        OnboardingTourWindow(
            scene: stageScene,
            agents: draft.orderedEnabledAgents,
            projectName: page == 3 ? draft.projectURL?.lastPathComponent : nil,
            isLaunching: isLaunching
        )
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private var stageScene: TourScene {
        switch page {
        case 0: TourChapter.all[chapter].scene
        case 1: .crew
        default: .launch
        }
    }

    /// A soft wash of colour behind the stage that follows the story.
    private var ambientGlow: some View {
        Circle()
            .fill(glowTint.gradient)
            .frame(width: 520, height: 420)
            .blur(radius: 120)
            .opacity(0.32)
            .offset(y: -40)
            .animation(.smooth(duration: 0.8), value: glowTint)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var glowTint: Color {
        switch page {
        case 0: TourChapter.all[chapter].tint
        case 1: .indigo
        case 2: draft.missingTools.isEmpty ? .green : .orange
        default: isLaunching ? FlotillaColors.statusWorking : FlotillaColors.accent
        }
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        Group {
            switch page {
            case 0: chapterControls
            case 1: crewControls
            default: launchControls
            }
        }
        .id(page)
        .transition(.opacity)
    }

    private var chapterControls: some View {
        let current = TourChapter.all[chapter]
        return VStack(spacing: FlotillaSpacing.large) {
            VStack(spacing: 4) {
                Text(current.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(FlotillaColors.textPrimary)
                Text(current.summary)
                    .font(FlotillaTypography.body)
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: 540)
            }
            .id(chapter)
            .transition(.opacity)
            .accessibilityElement(children: .combine)

            HStack(spacing: 6) {
                ForEach(Array(TourChapter.all.enumerated()), id: \.offset) { index, item in
                    ChapterChip(
                        chapter: item,
                        isSelected: index == chapter,
                        progress: isTourAutoPlaying && !reduceMotion ? chapterProgress : nil
                    ) {
                        isTourAutoPlaying = false
                        withAnimation(.smooth) { chapter = index }
                    }
                }
            }
        }
    }

    private var crewControls: some View {
        VStack(spacing: FlotillaSpacing.medium) {
            HStack(alignment: .top, spacing: FlotillaSpacing.medium) {
                ForEach(AgentKind.allCases) { agent in
                    CrewMedallion(
                        agent: agent,
                        isDetected: draft.detectedAgents.contains(agent),
                        isSelected: draft.isEnabled(agent)
                    ) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { draft.toggle(agent) }
                    }
                }
            }
            Text("Change your fleet anytime in Settings ▸ Agents.")
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textTertiary)
        }
    }

    private var launchControls: some View {
        SetupOptionsList(draft: draft)
            .frame(width: Self.stageSize.width)
            .disabled(isLaunching)
    }

    // MARK: Navigation

    private var navigationBar: some View {
        HStack {
            Button("Back") { go(to: page - 1) }
                .controlSize(.large)
                .opacity(page == 0 ? 0 : 1)
                .disabled(page == 0 || isLaunching)
            Spacer()
            OnboardingPageDots(count: Self.pageCount, index: Binding(get: { page }, set: { go(to: $0) }))
                .disabled(isLaunching)
            Spacer()
            Button(primaryTitle, action: primaryAction)
                .accessibilityIdentifier(AXID.onboardingPrimaryButton.rawValue)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(FlotillaColors.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(isLaunching)
        }
        .padding(.horizontal, FlotillaSpacing.xxLarge)
        .padding(.vertical, FlotillaSpacing.large)
    }

    private var primaryTitle: String {
        switch page {
        case 0: "Get Started"
        case Self.pageCount - 1: isLaunching ? "Launching…" : "Launch First Session"
        default: "Continue"
        }
    }

    private func primaryAction() {
        guard page == Self.pageCount - 1 else { return go(to: page + 1) }
        guard !reduceMotion else { return onFinish(.launched) }
        isLaunching = true
        Task {
            do { try await Task.sleep(for: .seconds(1.6)) } catch { return }
            onFinish(.launched)
        }
    }

    // MARK: Tour

    /// Fills the active chapter's progress line, then moves to the next one.
    private func playTour() async {
        guard page == 0, isTourAutoPlaying, !reduceMotion else { return }
        chapterProgress = 0
        // Let the reset render before animating, or the two collapse into one.
        try? await Task.sleep(for: .milliseconds(30))
        withAnimation(.linear(duration: Self.chapterDuration)) { chapterProgress = 1 }
        try? await Task.sleep(for: .seconds(Self.chapterDuration))
        guard !Task.isCancelled, page == 0, isTourAutoPlaying else { return }
        withAnimation(.smooth) { chapter = (chapter + 1) % TourChapter.all.count }
    }
}

private struct TourTick: Hashable {
    let page: Int
    let chapter: Int
}

// MARK: - Chapters

/// A use case the tour acts out on the stage.
struct TourChapter: Sendable {
    let scene: TourScene
    let symbol: String
    let tint: Color
    let label: String
    let title: String
    let summary: String

    static let all = [
        TourChapter(
            scene: .parallel,
            symbol: "square.stack.3d.up.fill",
            tint: FlotillaColors.statusFinished,
            label: "Parallel",
            title: "Ship in parallel",
            summary: "Three agents, three branches, one repo. Every session works in its own git worktree, so nobody steps on anybody."
        ),
        TourChapter(
            scene: .signals,
            symbol: "bell.badge.fill",
            tint: FlotillaColors.statusWaitingForInput,
            label: "Signals",
            title: "Stop babysitting terminals",
            summary: "Go do something else. The moment an agent needs you, its tile lights up and a notification taps you on the shoulder."
        ),
        TourChapter(
            scene: .handoff,
            symbol: "arrow.left.arrow.right",
            tint: .purple,
            label: "Handoff",
            title: "Never stall on a rate limit",
            summary: "Hand the live session to another agent. The whole conversation comes along — not a summary."
        ),
        TourChapter(
            scene: .review,
            symbol: "checkmark.seal.fill",
            tint: FlotillaColors.statusWorking,
            label: "Review",
            title: "Review like a tech lead",
            summary: "Read the diff, comment on a line, and send the review straight back to the agent that wrote it."
        ),
        TourChapter(
            scene: .phone,
            symbol: "iphone",
            tint: .green,
            label: "iPhone",
            title: "Approve from anywhere",
            summary: "Permission requests land on your iPhone. Tap Allow from the couch — end-to-end encrypted, no account."
        ),
    ]
}

private struct ChapterChip: View {
    let chapter: TourChapter
    let isSelected: Bool
    let progress: CGFloat?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: chapter.symbol)
                    .foregroundStyle(isSelected ? chapter.tint : FlotillaColors.textTertiary)
                Text(chapter.label)
                    .foregroundStyle(isSelected ? FlotillaColors.textPrimary : FlotillaColors.textSecondary)
            }
            .font(FlotillaTypography.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                FlotillaColors.surfaceElevated.opacity(isSelected ? 1 : (isHovered ? 0.5 : 0)),
                in: Capsule()
            )
            .overlay(alignment: .bottom) {
                if isSelected, let progress {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(chapter.tint)
                            .frame(width: proxy.size.width * progress, height: 2)
                    }
                    .frame(height: 2)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 3)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(chapter.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Shows this use case in the preview")
    }
}

// MARK: - Crew

/// One agent as a big, toggleable logo. Agents that aren't installed can
/// still be picked; they link to their install guide.
private struct CrewMedallion: View {
    let agent: AgentKind
    let isDetected: Bool
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: FlotillaSpacing.small) {
            Button(action: action) {
                ProviderLogo(agent: agent)
                    .frame(width: 34, height: 34)
                    .frame(width: 76, height: 76)
                    .background(FlotillaColors.surface, in: Circle())
                    .overlay {
                        Circle().strokeBorder(
                            isSelected ? FlotillaColors.accent : FlotillaColors.separator,
                            lineWidth: isSelected ? 2.5 : 1
                        )
                    }
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, FlotillaColors.accent)
                                .background(Circle().fill(FlotillaColors.canvas).padding(2))
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .saturation(isSelected ? 1 : 0.15)
                    .opacity(isSelected ? 1 : 0.65)
                    .scaleEffect(isHovered ? 1.05 : 1)
                    .shadow(color: isSelected ? FlotillaColors.accent.opacity(0.35) : .clear, radius: 12)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.snappy) { isHovered = hovering }
            }
            .accessibilityLabel(agent.displayName)
            .accessibilityValue(isDetected ? "Installed" : "Not installed")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier(AXID.onboardingAgentToggle.rawValue + agent.rawValue)

            Text(agent.displayName)
                .font(FlotillaTypography.callout.weight(.semibold))
                .foregroundStyle(isSelected ? FlotillaColors.textPrimary : FlotillaColors.textSecondary)
                .lineLimit(1)
                .fixedSize()
            if isDetected {
                Text("Installed")
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textTertiary)
            } else {
                Link("Get It ↗", destination: agent.installGuideURL)
                    .font(FlotillaTypography.caption)
            }
        }
        .frame(width: 112)
    }
}

/// Owns the draft for one showing of the sheet, and records the outcome:
/// onboarding counts as done either way, but only finishing applies choices.
struct OnboardingPresenter: View {
    let store: AppStore
    let settingsViewModel: SettingsViewModel
    let navigator: WorkspaceNavigator

    @State private var draft: OnboardingDraft

    init(store: AppStore, settingsViewModel: SettingsViewModel, startupCheck: StartupCheckViewModel, navigator: WorkspaceNavigator) {
        self.store = store
        self.settingsViewModel = settingsViewModel
        self.navigator = navigator
        // A UI test must never raise the real, out-of-process permission prompt.
        let isUITesting = ProcessInfo.processInfo.environment["UI_TESTING"] == "1"
        _draft = State(initialValue: OnboardingDraft(
            startupCheck: startupCheck,
            settings: settingsViewModel.settings,
            requestNotificationAuthorization: {
                if isUITesting { return true }
                return await OnboardingDraft.requestSystemAuthorization()
            }
        ))
    }

    var body: some View {
        OnboardingSheet(draft: draft) { outcome in
            var settings = settingsViewModel.settings
            settings.onboardingVersion = OnboardingSheet.currentVersion
            let projectID = outcome == .launched ? draft.apply(to: &settings, store: store) : nil
            settingsViewModel.settings = settings
            navigator.presentedSheet = outcome == .launched ? .createSession(projectID: projectID) : nil
        }
    }
}

#Preview("Onboarding") {
    OnboardingSheet(draft: .preview(), onFinish: { _ in })
}
