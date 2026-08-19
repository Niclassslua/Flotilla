import SwiftUI
import SessionKit
import SettingsKit
import DesignSystem

/// The overview screen: a glass composer floating on a sunset canvas built from
/// `FlotillaColors.accent` — the same ramp as the app icon — with the fleet
/// summarised beneath it.
///
/// Launching is the primary job here, so the composer is the only thing above
/// the fold. Everything below it is triage: what needs a human first, then what
/// ran most recently, then the projects those sessions belong to.
struct HomeDashboardView: View {
    @Bindable var store: AppStore
    let openProject: (UUID) -> Void
    let openSession: (UUID) -> Void
    @Bindable var settingsViewModel: SettingsViewModel
    let activityStore: SessionActivityStore?
    let terminalManager: TerminalManager?
    let openCodeSubscription: OpenCodeSubscription
    let defaultAgent: AgentKind

    @State private var selectedProjectID: UUID?

    init(
        store: AppStore,
        openProject: @escaping (UUID) -> Void,
        openSession: @escaping (UUID) -> Void,
        settingsViewModel: SettingsViewModel,
        activityStore: SessionActivityStore? = nil,
        terminalManager: TerminalManager? = nil,
        openCodeSubscription: OpenCodeSubscription = .none,
        defaultAgent: AgentKind = .claudeCode
    ) {
        self.store = store
        self.openProject = openProject
        self.openSession = openSession
        self.settingsViewModel = settingsViewModel
        self.activityStore = activityStore
        self.terminalManager = terminalManager
        self.openCodeSubscription = openCodeSubscription
        self.defaultAgent = defaultAgent
    }

    private var context: HomeContext {
        HomeContext(
            store: store,
            settings: settingsViewModel.settings,
            activityStore: activityStore,
            openCodeSubscription: openCodeSubscription,
            defaultAgent: defaultAgent,
            openProject: { id in
                withAnimation(.snappy(duration: 0.2)) {
                    selectedProjectID = id
                }
                openProject(id)
            },
            openSession: openSession
        )
    }

    private var stats: HomeFleetStats { context.fleetStats }

    private var activeDrilldownProject: Project? {
        if let id = selectedProjectID ?? store.selectedProjectID {
            return store.projects.first { $0.id == id }
        }
        return nil
    }

    var body: some View {
        Group {
            if let project = activeDrilldownProject {
                ProjectDetailView(
                    project: project,
                    sessions: store.sessions(for: project),
                    store: store,
                    terminalManager: terminalManager ?? TerminalManager(),
                    openSession: openSession,
                    openCodeSubscription: openCodeSubscription,
                    onBackToOverview: {
                        withAnimation(.snappy(duration: 0.2)) {
                            selectedProjectID = nil
                            store.selectedProjectID = nil
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                    removal: .opacity.combined(with: .move(edge: .trailing))
                ))
            } else {
                overviewDashboard
                    .transition(.opacity)
            }
        }
        .accessibilityIdentifier(AXID.homeDashboard.rawValue)
    }

    private var overviewDashboard: some View {
        ScrollView {
            VStack(spacing: FlotillaSpacing.xLarge) {
                FlotillaHeroTitleView(stats: stats)
                composer
                fleet
            }
            .padding(.horizontal, FlotillaSpacing.xxLarge)
            .padding(.top, FlotillaSpacing.medium)
            .padding(.bottom, FlotillaSpacing.xxLarge)
            .frame(maxWidth: 1_440, alignment: .center)
            .frame(maxWidth: .infinity)
        }
        .background {
            harborGradient.ignoresSafeArea()
        }
    }

    // MARK: - Composer

    private var composer: some View {
        SessionLaunchForm(
            store: store,
            settings: settingsViewModel.settings,
            defaultAgent: defaultAgent,
            initialProject: nil,
            openCodeSubscription: openCodeSubscription,
            density: .chromeless,
            onLaunch: openSession,
            onCancel: {}
        )
        .padding(FlotillaSpacing.large)
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: FlotillaRadius.modal, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.modal, style: .continuous)
                .strokeBorder(FlotillaColors.accent.opacity(0.22), lineWidth: FlotillaBorderWidth.thin)
        }
        .flotillaShadow(.level3)
    }

    // MARK: - Fleet

    private var fleet: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.xxLarge) {
            HomeAttentionQueue(context: context, style: .panel)
            HomeRecentSessionsList(context: context, limit: 6)
            HomeProjectsGallery(context: context) { id in
                withAnimation(.snappy(duration: 0.2)) {
                    selectedProjectID = id
                    store.selectedProjectID = id
                }
            }
            .padding(.top, FlotillaSpacing.small)
        }
    }

    private var harborGradient: some View {
        LinearGradient(
            stops: [
                .init(color: FlotillaColors.accent.opacity(0.18), location: 0),
                .init(color: FlotillaColors.accent.opacity(0.11), location: 0.32),
                .init(color: FlotillaColors.accent.opacity(0.04), location: 0.56),
                .init(color: FlotillaColors.canvas, location: 0.78),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .background(FlotillaColors.canvas)
    }
}

#if DEBUG
#Preview("Home") {
    HomeDashboardView(
        store: HomePreviewData.makeStore(),
        openProject: { _ in },
        openSession: { _ in },
        settingsViewModel: SettingsViewModel(
            store: UserDefaultsSettingsStore(defaultWorktreeBaseDirectory: NSTemporaryDirectory())
        ),
        activityStore: nil
    )
    .frame(width: 1_080, height: 820)
}
#endif
