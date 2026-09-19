import SwiftUI
import SessionKit
import SettingsKit
import PersistenceKit
import DesignSystem

/// What a widget's project setting resolves to against the projects that
/// exist right now.
enum HomeWidgetProjectScope {
    case all
    case project(Project)
    /// The saved project no longer exists.
    case removed

    var id: UUID? {
        if case .project(let project) = self { return project.id }
        return nil
    }
}

func homeWidgetResolveProjectScope(config: HomeWidgetConfig, projects: [Project]) -> HomeWidgetProjectScope {
    guard let raw = config.projectID, let id = UUID(uuidString: raw) else { return .all }
    if let project = projects.first(where: { $0.id == id }) { return .project(project) }
    return .removed
}

extension HomeWidgetSize {
    var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .wide: "Wide"
        }
    }
}

/// One placed widget: resolves its settings against live data, renders the
/// right content for its kind and size inside `HomeWidgetCard`, and — on the
/// grid, in edit mode — carries the remove, settings and resize controls.
/// `isPreview` renders the same widget inert, for the gallery.
struct HomeWidgetView: View {
    let entry: HomeWidgetEntry
    let size: HomeWidgetSize
    @Bindable var store: AppStore
    @Bindable var insights: HomeInsights
    var editor: HomeWidgetEditor?
    var isPreview = false
    var openSession: (UUID) -> Void = { _ in }
    /// Drives the corner handle; `nil` hides it (single-size widgets,
    /// previews). Reports the handle's translation, then its end.
    var onResizeChanged: ((CGSize) -> Void)?
    var onResizeEnded: (() -> Void)?

    @State private var presentsSettings = false
    @State private var isHovering = false
    @State private var fileChurn: [String: Int] = [:]
    @State private var isLoadingFileChurn = false
    @State private var permissions: [PermissionPatternCount] = []
    @State private var screenshotFeed = HomeScreenshotFeed()
    @Environment(\.undoManager) private var undoManager

    private var kind: HomeWidgetKind? { entry.resolvedKind }
    private var isEditing: Bool { !isPreview && (editor?.isEditing ?? false) }
    private var scope: HomeWidgetProjectScope { homeWidgetResolveProjectScope(config: entry.config, projects: store.projects) }

    var body: some View {
        if let kind {
            HomeWidgetCard(
                kind: kind,
                count: count(for: kind),
                configSummary: configSummary(for: kind),
                isEditing: isEditing,
                content: { content(for: kind) }
            )
            .overlay(alignment: .topLeading) { if isEditing { removeBadge(kind) } }
            .overlay(alignment: .topTrailing) { if isEditing, hasSettings(kind) { settingsBadge(kind) } }
            .overlay(alignment: .bottomTrailing) { if isEditing, onResizeChanged != nil { resizeHandle(kind) } }
            .onHover { isHovering = $0 }
            .allowsHitTesting(!isPreview)
            .popover(isPresented: $presentsSettings) {
                if let editor {
                    HomeWidgetSettingsPopover(kind: kind, entry: entry, store: store, editor: editor)
                }
            }
            .contextMenu { if !isPreview { contextMenuItems(for: kind) } }
            .modifier(HomeWidgetAccessibilityActionsModifier(
                kind: kind,
                isEnabled: !isPreview && editor != nil,
                onResize: { editor?.setSize(id: entry.id, to: $0) },
                onMoveEarlier: { editor?.moveEarlier(id: entry.id) },
                onMoveLater: { editor?.moveLater(id: entry.id) },
                onRemove: { editor?.remove(id: entry.id) },
                onEditSettings: hasSettings(kind) ? { presentsSettings = true } : nil
            ))
        }
    }

    // MARK: - Edit controls

    private func removeBadge(_ kind: HomeWidgetKind) -> some View {
        Button(role: .destructive) { editor?.remove(id: entry.id) } label: {
            Image(systemName: "minus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(FlotillaColors.statusCrashed, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .offset(x: -7, y: -7)
        .help("Remove widget")
        .accessibilityLabel("Remove \(kind.title) widget")
        .accessibilityIdentifier(AXID.homeWidgetRemoveBadge.rawValue + kind.rawValue)
    }

    private func settingsBadge(_ kind: HomeWidgetKind) -> some View {
        Button { presentsSettings = true } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(FlotillaColors.textPrimary)
                .frame(width: 22, height: 22)
                .background(FlotillaColors.surfaceElevated, in: Circle())
                .overlay(Circle().strokeBorder(FlotillaColors.textPrimary.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(8)
        .help("Widget settings")
        .accessibilityLabel("Edit \(kind.title) widget settings")
        .accessibilityIdentifier(AXID.homeWidgetInfoBadge.rawValue + kind.rawValue)
    }

    /// A corner grip, shown while hovering. `highPriorityGesture` so it wins
    /// over the card's own drag-to-move.
    private func resizeHandle(_ kind: HomeWidgetKind) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(FlotillaColors.textPrimary)
            .frame(width: 22, height: 22)
            .background(FlotillaColors.surfaceElevated, in: Circle())
            .overlay(Circle().strokeBorder(FlotillaColors.textPrimary.opacity(0.18), lineWidth: 1))
            .padding(6)
            .contentShape(Rectangle())
            .opacity(isHovering || editor?.resize?.id == entry.id ? 1 : 0.55)
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { onResizeChanged?($0.translation) }
                    .onEnded { _ in onResizeEnded?() }
            )
            .pointerStyle(.frameResize(position: .bottomTrailing))
            .help("Drag to resize")
            .accessibilityLabel("Resize \(kind.title) widget")
            .accessibilityIdentifier(AXID.homeWidgetResizeHandle.rawValue + kind.rawValue)
    }

    @ViewBuilder
    private func contextMenuItems(for kind: HomeWidgetKind) -> some View {
        if kind.supportedSizes.count > 1 {
            Picker("Size", selection: Binding(
                get: { size },
                set: { editor?.setSize(id: entry.id, to: $0) }
            )) {
                ForEach(kind.supportedSizes, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
        }
        Button("Move Earlier") { editor?.moveEarlier(id: entry.id) }
        Button("Move Later") { editor?.moveLater(id: entry.id) }
        if hasSettings(kind) {
            Button("Edit Widget…") { presentsSettings = true }
        }
        Divider()
        Button("Remove Widget", role: .destructive) { editor?.remove(id: entry.id) }
        if let editor, !editor.isEditing {
            Divider()
            Button("Edit Widgets…") { editor.beginEditing(undoManager: undoManager) }
        }
    }

    // MARK: - Header

    private func count(for kind: HomeWidgetKind) -> Int? {
        switch kind {
        case .needsYou: filteredWaiting.count
        case .reviewQueue: filteredReview.count
        default: nil
        }
    }

    private func hasSettings(_ kind: HomeWidgetKind) -> Bool {
        kind.hasProjectFilter || kind.timeWindowOptionsDays != nil || kind.hasAgentFilter
    }

    private func configSummary(for kind: HomeWidgetKind) -> HomeWidgetConfigSummary {
        var summary = HomeWidgetConfigSummary()
        if case .project(let project) = scope { summary.projectName = project.name }
        if let days = entry.config.timeWindowDays, days != kind.defaultTimeWindowDays {
            summary.timeWindowLabel = "\(days)d"
        }
        if let raw = entry.config.agent, let agent = AgentKind(rawValue: raw) {
            summary.agentLabel = agent.displayName
        }
        return summary
    }

    // MARK: - Data

    private var windowDays: Int { entry.config.timeWindowDays ?? kind?.defaultTimeWindowDays ?? 30 }
    private var configuredAgent: AgentKind? { entry.config.agent.flatMap(AgentKind.init(rawValue:)) }

    private var filteredWaiting: [HomeWaitingItem] {
        scope.id.map { id in insights.waitingItems.filter { $0.project.id == id } } ?? insights.waitingItems
    }

    private var filteredReview: [HomeReviewItem] {
        scope.id.map { id in insights.reviewItems.filter { $0.project.id == id } } ?? insights.reviewItems
    }

    private var sessionsStartedToday: Int {
        let today = Calendar.current.startOfDay(for: .now)
        let sessions = scope.id.map { id in store.sessions.filter { $0.projectID == id } } ?? store.sessions
        return sessions.filter { Calendar.current.startOfDay(for: $0.createdAt) == today }.count
    }

    // MARK: - Content

    @ViewBuilder
    private func content(for kind: HomeWidgetKind) -> some View {
        switch scope {
        case .removed:
            HomeWidgetProjectRemovedState(onPick: { presentsSettings = true })
        default:
            switch kind {
            case .needsYou:
                NeedsYouWidgetContent(size: size, items: filteredWaiting, openSession: openSession)
            case .reviewQueue:
                ReviewQueueWidgetContent(size: size, items: filteredReview, openSession: openSession)
            case .looseEnds:
                LooseEndsWidgetContent(size: size, rows: looseEndRows)
            case .streak:
                StreakWidgetContent(activity: insights.activity(for: scope.id))
            case .today:
                TodayWidgetContent(size: size, activity: insights.activity(for: scope.id), sessionsStartedToday: sessionsStartedToday)
            case .busiestHours:
                BusiestHoursWidgetContent(
                    size: size,
                    grid: insights.activity(for: scope.id)?.commitsByWeekdayHour(windowDays: windowDays)
                        ?? Array(repeating: Array(repeating: 0, count: 24), count: 7)
                )
            case .hotFiles:
                HotFilesWidgetContent(size: size, churn: fileChurn, isLoading: isLoadingFileChurn)
                    .task(id: "\(scope.id?.uuidString ?? "all")|\(windowDays)") {
                        isLoadingFileChurn = true
                        fileChurn = await insights.fileChurn(store: store, projectID: scope.id, windowDays: windowDays)
                        isLoadingFileChurn = false
                    }
            case .topPermissions:
                TopPermissionsWidgetContent(size: size, patterns: permissions)
                    .task(id: "\(scope.id?.uuidString ?? "all")|\(windowDays)|\(configuredAgent?.rawValue ?? "all")") {
                        permissions = insights.topPermissions(store: store, projectID: scope.id, windowDays: windowDays, agent: configuredAgent)
                    }
            case .contributions:
                ContributionsWidgetContent(size: size, activity: insights.activity(for: scope.id))
            case .weeklyRhythm:
                RhythmChartContent(linesByDay: insights.activity(for: scope.id)?.linesByDay ?? [:], windowDays: windowDays)
            case .agentShare:
                let activity = insights.activity(for: scope.id)
                AgentShareWidgetContent(size: size, contributions: activity?.contributions ?? [:], linesByContributor: activity?.linesByContributor ?? [:])
            case .codebaseGrowth:
                GrowthChartContent(
                    netLinesByWeek: insights.activity(for: scope.id)?.netLinesByWeek ?? [:],
                    projects: store.projects,
                    windowWeeks: max(1, windowDays / 7)
                )
            case .agentScreenshots:
                AgentScreenshotsWidgetContent(size: size, shots: screenshotFeed.shots, isLoading: screenshotFeed.isLoading)
                    .task(id: "\(scope.id?.uuidString ?? "all")|\(configuredAgent?.rawValue ?? "all")") {
                        await screenshotFeed.refresh(store: store, projectID: scope.id, agent: configuredAgent)
                    }
            }
        }
    }

    private var looseEndRows: [LooseEndsWidgetContent.ProjectRow] {
        (scope.id.map { id in store.projects.filter { $0.id == id } } ?? store.projects)
            .compactMap { project in
                insights.repoStates[project.id].map { .init(id: project.id, name: project.name, state: $0) }
            }
    }
}

/// `.accessibilityAction(named:)` is chained, not built from an array, so a
/// variable-length set (one per supported size, plus the fixed ones) goes
/// through a loop with `AnyView` erasure.
private struct HomeWidgetAccessibilityActionsModifier: ViewModifier {
    let kind: HomeWidgetKind
    let isEnabled: Bool
    let onResize: (HomeWidgetSize) -> Void
    let onMoveEarlier: () -> Void
    let onMoveLater: () -> Void
    let onRemove: () -> Void
    let onEditSettings: (() -> Void)?

    func body(content: Content) -> some View {
        guard isEnabled else { return AnyView(content) }
        var view = AnyView(content)
        for candidate in kind.supportedSizes where kind.supportedSizes.count > 1 {
            view = AnyView(view.accessibilityAction(named: Text("Size: \(candidate.label)")) { onResize(candidate) })
        }
        view = AnyView(view.accessibilityAction(named: Text("Move Earlier")) { onMoveEarlier() })
        view = AnyView(view.accessibilityAction(named: Text("Move Later")) { onMoveLater() })
        view = AnyView(view.accessibilityAction(named: Text("Remove Widget")) { onRemove() })
        if let onEditSettings {
            view = AnyView(view.accessibilityAction(named: Text("Edit Widget Settings")) { onEditSettings() })
        }
        return view
    }
}
