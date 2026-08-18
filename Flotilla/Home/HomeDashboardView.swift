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
    let openCodeSubscription: OpenCodeSubscription
    let defaultAgent: AgentKind

    init(
        store: AppStore,
        openProject: @escaping (UUID) -> Void,
        openSession: @escaping (UUID) -> Void,
        settingsViewModel: SettingsViewModel,
        activityStore: SessionActivityStore? = nil,
        openCodeSubscription: OpenCodeSubscription = .none,
        defaultAgent: AgentKind = .claudeCode
    ) {
        self.store = store
        self.openProject = openProject
        self.openSession = openSession
        self.settingsViewModel = settingsViewModel
        self.activityStore = activityStore
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
            openProject: openProject,
            openSession: openSession
        )
    }

    private var stats: HomeFleetStats { context.fleetStats }

    var body: some View {
        ScrollView {
            VStack(spacing: FlotillaSpacing.xxLarge) {
                composer
                fleet
            }
            .padding(.horizontal, FlotillaSpacing.xxLarge)
            .padding(.top, FlotillaSpacing.xxLarge)
            .padding(.bottom, FlotillaSpacing.xxLarge)
            .frame(maxWidth: 1_040, alignment: .center)
            .frame(maxWidth: .infinity)
        }
        .background {
            harborGradient.ignoresSafeArea()
        }
        .accessibilityIdentifier(AXID.homeDashboard.rawValue)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
            HStack(spacing: FlotillaSpacing.small) {
                Image(systemName: "sailboat.fill")
                    .font(.system(size: FlotillaIconSize.medium, weight: .medium))
                    .foregroundStyle(FlotillaColors.accent)
                    .accessibilityHidden(true)
                Text(stats.total == 0 ? "Launch the first agent" : stats.summary)
                    .font(FlotillaTypography.callout)
                    .foregroundStyle(FlotillaColors.textSecondary)
                Spacer(minLength: 0)
            }

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
        }
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
        VStack(alignment: .leading, spacing: FlotillaSpacing.xLarge) {
            HomeAttentionQueue(context: context, style: .panel)
            HomeRecentSessionsList(context: context, limit: 6)
            HomeRecentProjectsGrid(context: context, limit: 4, minimumTileWidth: 210)
        }
    }

    private var harborGradient: some View {
        // Explicit stops rather than evenly-spaced colors: the sunset holds
        // through the upper half and only settles into the canvas past the
        // midpoint, so the warmth carries the composer instead of stopping
        // right beneath it.
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
