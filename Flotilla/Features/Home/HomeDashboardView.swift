import SwiftUI
import SessionKit
import SettingsKit
import DesignSystem

/// Home: the lobby you pass through on the way into a project.
///
/// It shows only what no other screen does. The sidebar already lists every
/// session with its status, and a project workspace already details one
/// repository — so Home has neither a session list nor a composer (⌘N is the
/// one way to start a session). What's left is the choice of where to go:
/// each project's loose ends at a glance, then your work over time.
struct HomeDashboardView: View {
    @Bindable var store: AppStore
    let openProject: (UUID) -> Void
    let openSession: (UUID) -> Void
    @Bindable var settingsViewModel: SettingsViewModel
    let insights: HomeInsights

    @State private var presentedSheet: ProjectSheetType?
    @Environment(\.flotillaLiquidGlassEnabled) private var liquidGlassEnabled
    @State private var widgetEditor: HomeWidgetEditor

    init(
        store: AppStore,
        openProject: @escaping (UUID) -> Void,
        openSession: @escaping (UUID) -> Void,
        settingsViewModel: SettingsViewModel,
        insights: HomeInsights
    ) {
        self.store = store
        self.openProject = openProject
        self.openSession = openSession
        self.settingsViewModel = settingsViewModel
        self.insights = insights
        _widgetEditor = State(initialValue: HomeWidgetEditor(settings: .init(
            get: { settingsViewModel.settings.workspace.homeWidgets },
            set: { settingsViewModel.settings.workspace.homeWidgets = $0 }
        )))
    }

    /// Most recently worked-on first: the project you touched last is the one
    /// you most likely want next.
    private var projects: [Project] {
        store.projects.sorted { lhs, rhs in
            let lhsDate = store.sessions(for: lhs).map(\.lastActiveAt).max() ?? .distantPast
            let rhsDate = store.sessions(for: rhs).map(\.lastActiveAt).max() ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FlotillaSpacing.xxLarge + FlotillaSpacing.large) {
                greeting
                projectsSection
                if !store.projects.isEmpty {
                    HomeWidgetGrid(store: store, insights: insights, editor: widgetEditor, openSession: openSession)
                }
            }
            .padding(.horizontal, FlotillaSpacing.xxLarge + FlotillaSpacing.small)
            .padding(.top, FlotillaSpacing.xxLarge)
            .padding(.bottom, FlotillaSpacing.xxLarge + FlotillaSpacing.large)
            .frame(maxWidth: 1_280)
            .frame(maxWidth: .infinity)
        }
        .background { backdrop.ignoresSafeArea() }
        .sheet(item: $presentedSheet) { sheet in
            ProjectPathSheet(importsWorkspace: sheet == .importWorkspace) { paths in
                for path in paths { store.addProject(at: path) }
                presentedSheet = nil
            }
        }
        .accessibilityIdentifier(AXID.homeDashboard.rawValue)
    }

    // MARK: - Greeting

    private var greeting: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.xSmall) {
            Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                .font(FlotillaTypography.callout.weight(.medium))
                .foregroundStyle(FlotillaColors.accent)
            Text(Self.greetingText)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .tracking(-0.4)
                .foregroundStyle(FlotillaColors.textPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AXID.homeGreeting.rawValue)
    }

    static var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let greeting = switch hour {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<23: "Good evening"
        default: "Working late"
        }
        let fullName = NSFullUserName()
        let name = fullName.isEmpty
            ? NSUserName().capitalized
            : fullName.split(separator: " ").first.map(String.init) ?? fullName
        return "\(greeting), \(name)"
    }

    // MARK: - Projects

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
            HStack(alignment: .firstTextBaseline, spacing: FlotillaSpacing.small) {
                HomeSectionTitle("Projects", count: store.projects.count)
                Spacer(minLength: FlotillaSpacing.medium)
                Button {
                    presentedSheet = .importWorkspace
                } label: {
                    Label("Import Workspace", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .help("Scan a folder for local Git repositories")
                Button {
                    presentedSheet = .add
                } label: {
                    Label("Add Project", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(FlotillaColors.accent)
                .help("Add a repository to Flotilla")
                .accessibilityIdentifier("Projects.ImportButton")
            }
            .controlSize(.regular)

            if projects.isEmpty {
                emptyProjects
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 340, maximum: 420), spacing: FlotillaSpacing.large)],
                    spacing: FlotillaSpacing.large
                ) {
                    ForEach(projects) { project in
                        HomeProjectCard(
                            project: project,
                            sessions: store.sessions(for: project),
                            repoState: insights.repoStates[project.id],
                            commitAttribution: settingsViewModel.settings.git.projectCommitAttribution[project.id.uuidString],
                            defaultCommitAttribution: settingsViewModel.settings.git.defaultCommitAttribution,
                            onSetCommitAttribution: { [settingsViewModel] mode in
                                settingsViewModel.settings.git.projectCommitAttribution[project.id.uuidString] = mode
                            },
                            onSelect: { openProject(project.id) },
                            onRemove: { store.removeProject(id: project.id) },
                            onUpdateIdentity: { store.updateProjectIdentity(id: project.id, icon: $0, accentColor: $1) },
                            onUpdateAccentColor: { store.updateProjectAccentColor(id: project.id, accentColor: $0) }
                        )
                    }
                }
                .accessibilityIdentifier(AXID.homeRecentProjects.rawValue)
            }
        }
    }

    private var emptyProjects: some View {
        VStack(spacing: FlotillaSpacing.small) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(FlotillaColors.accent)
            Text("Add your first repository")
                .font(FlotillaTypography.headline)
                .foregroundStyle(FlotillaColors.textPrimary)
            Text("Projects you add show up here with their branch, uncommitted work and unpushed commits.")
                .font(FlotillaTypography.callout)
                .foregroundStyle(FlotillaColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(FlotillaSpacing.xxLarge)
        .flotillaLiquidSurface(
            FlotillaColors.surface,
            cornerRadius: FlotillaRadius.modal,
            glassTintOpacity: FlotillaGlassTint.elevated
        )
    }

    // MARK: - Background

    @ViewBuilder
    private var backdrop: some View {
        if liquidGlassEnabled {
            tideGradient
        } else {
            harborGradient
        }
    }

    /// Glass on: the accent wash fades into transparency rather than canvas,
    /// so the window's glass shows through below it and the glass cards have
    /// light to refract.
    private var tideGradient: some View {
        LinearGradient(
            stops: [
                .init(color: FlotillaColors.accent.opacity(0.42), location: 0),
                .init(color: FlotillaColors.accent.opacity(0.16), location: 0.28),
                .init(color: FlotillaColors.accent.opacity(0), location: 0.55),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Glass off: the warm wash the old composer floated on — the app icon's accent ramp
    /// fading into the canvas.
    private var harborGradient: some View {
        LinearGradient(
            stops: [
                .init(color: FlotillaColors.accent.opacity(0.18), location: 0),
                .init(color: FlotillaColors.accent.opacity(0.11), location: 0.28),
                .init(color: FlotillaColors.accent.opacity(0.04), location: 0.52),
                .init(color: FlotillaColors.canvas, location: 0.8),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .background(FlotillaColors.canvas)
    }
}

/// Section heading on Home: rounded, sentence case, with an optional count.
struct HomeSectionTitle: View {
    let title: String
    var count: Int?

    init(_ title: String, count: Int? = nil) {
        self.title = title
        self.count = count
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: FlotillaSpacing.small) {
            Text(title)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(FlotillaColors.textPrimary)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 15, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
        }
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
        insights: HomeInsights()
    )
    .frame(width: 1_180, height: 900)
}
#endif
