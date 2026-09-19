import SwiftUI
import SessionKit
import SettingsKit
import DesignSystem

/// What a widget's project setting resolves to, once checked against the
/// projects that currently exist.
enum HomeWidgetProjectScope {
    case all
    case project(Project)
    /// The saved `projectID` no longer names a project — Q24's "Project
    /// removed" state.
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

/// Renders one placed widget: resolves its config against live data, picks
/// the right content view for its kind and size, and wraps it all in
/// `HomeWidgetCard` — including the edit-mode chrome, which it wires
/// straight to `HomeWidgetEditor`.
struct HomeWidgetView: View {
    let entry: HomeWidgetEntry
    @Bindable var store: AppStore
    @Bindable var insights: HomeInsights
    let editor: HomeWidgetEditor
    let openSession: (UUID) -> Void

    @State private var presentsSettings = false
    @State private var fileChurn: [String: Int] = [:]
    @State private var isLoadingFileChurn = false
    @State private var screenshotFeed = HomeScreenshotFeed()
    @Environment(\.undoManager) private var undoManager

    private var kind: HomeWidgetKind? { entry.resolvedKind }
    private var size: HomeWidgetSize { entry.resolvedSize ?? kind?.defaultSize ?? .medium }
    private var scope: HomeWidgetProjectScope { homeWidgetResolveProjectScope(config: entry.config, projects: store.projects) }

    var body: some View {
        if let kind {
            HomeWidgetCard(
                kind: kind,
                size: size,
                count: count(for: kind),
                configSummary: configSummary(for: kind),
                content: { content(for: kind) },
                isEditing: editor.isEditing,
                onRemove: { editor.remove(id: entry.id) },
                onShowSettings: hasSettings(kind) ? { presentsSettings = true } : nil,
                onBeginResize: kind.supportedSizes.count > 1 ? { translation in
                    editor.resizing = (entry.id, resizedSize(from: translation))
                } : nil,
                onCommitResize: {
                    if let resizing = editor.resizing, resizing.id == entry.id {
                        editor.resize(id: entry.id, to: resizing.proposedSize)
                    }
                    editor.resizing = nil
                }
            )
            .homeWidgetSpan(
                columns: liveSize == .wide ? Int.max : liveSize.columnSpan,
                rows: liveSize.rowSpan
            )
            .popover(isPresented: $presentsSettings) {
                HomeWidgetSettingsPopover(kind: kind, entry: entry, store: store, editor: editor)
            }
            .contextMenu { contextMenuItems(for: kind) }
            .modifier(HomeWidgetAccessibilityActionsModifier(
                kind: kind,
                sizeLabel: sizeLabel,
                onResize: { editor.resize(id: entry.id, to: $0) },
                onMoveEarlier: { editor.moveEarlier(id: entry.id) },
                onMoveLater: { editor.moveLater(id: entry.id) },
                onRemove: { editor.remove(id: entry.id) },
                onEditSettings: hasSettings(kind) ? { presentsSettings = true } : nil
            ))
        }
    }

    @ViewBuilder
    private func contextMenuItems(for kind: HomeWidgetKind) -> some View {
        if kind.supportedSizes.count > 1 {
            Menu("Size") {
                ForEach(kind.supportedSizes, id: \.self) { candidate in
                    Button {
                        editor.resize(id: entry.id, to: candidate)
                    } label: {
                        if candidate == size {
                            Label(sizeLabel(candidate), systemImage: "checkmark")
                        } else {
                            Text(sizeLabel(candidate))
                        }
                    }
                }
            }
        }
        Button("Move Earlier") { editor.moveEarlier(id: entry.id) }
        Button("Move Later") { editor.moveLater(id: entry.id) }
        if hasSettings(kind) {
            Button("Edit Widget…") { presentsSettings = true }
        }
        Divider()
        Button("Remove Widget", role: .destructive) { editor.remove(id: entry.id) }
        if !editor.isEditing {
            Divider()
            Button("Edit Widgets…") { editor.beginEditing(undoManager: undoManager) }
        }
    }

    private func sizeLabel(_ size: HomeWidgetSize) -> String {
        switch size {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .wide: "Wide"
        }
    }

    /// The size to lay out at: the live resize preview while dragging this
    /// widget's own handle, else its committed size.
    private var liveSize: HomeWidgetSize {
        if let resizing = editor.resizing, resizing.id == entry.id { return resizing.proposedSize }
        return size
    }

    private func resizedSize(from translation: CGSize) -> HomeWidgetSize {
        guard let kind else { return size }
        let supported = kind.supportedSizes
        // Growing right/down moves toward wider sizes; shrinking moves back.
        // Ordered by area so the nearest neighbor in either direction is a
        // one-step change, not a jump across the whole list.
        let ordered = supported.sorted { $0.columnSpan * $0.rowSpan < $1.columnSpan * $1.rowSpan }
        guard ordered.count > 1 else { return size }
        let delta = translation.width + translation.height
        let currentIndex = ordered.firstIndex(of: size) ?? 0
        let step = delta > 60 ? 1 : (delta < -60 ? -1 : 0)
        let index = min(max(currentIndex + step, 0), ordered.count - 1)
        return ordered[index]
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
                ReviewQueueWidgetContent(items: filteredReview, openSession: openSession)
            case .looseEnds:
                let rows = (scope.id.map { id in store.projects.filter { $0.id == id } } ?? store.projects)
                    .compactMap { project -> LooseEndsWidgetContent.ProjectRow? in
                        guard let state = insights.repoStates[project.id] else { return nil }
                        return .init(id: project.id, name: project.name, state: state)
                    }
                LooseEndsWidgetContent(rows: rows)
            case .streak:
                StreakWidgetContent(activity: insights.activity(for: scope.id))
            case .today:
                TodayWidgetContent(size: size, activity: insights.activity(for: scope.id), sessionsStartedToday: sessionsStartedToday)
            case .busiestHours:
                let activity = insights.activity(for: scope.id)
                BusiestHoursWidgetContent(grid: activity?.commitsByWeekdayHour(windowDays: windowDays) ?? Array(repeating: Array(repeating: 0, count: 24), count: 7))
            case .hotFiles:
                HotFilesWidgetContent(churn: fileChurn, isLoading: isLoadingFileChurn)
                    .task(id: "\(scope.id?.uuidString ?? "all")|\(windowDays)") {
                        isLoadingFileChurn = true
                        fileChurn = await insights.fileChurn(store: store, projectID: scope.id, windowDays: windowDays)
                        isLoadingFileChurn = false
                    }
            case .topPermissions:
                TopPermissionsWidgetContent(
                    size: size,
                    patterns: insights.topPermissions(store: store, projectID: scope.id, windowDays: windowDays, agent: configuredAgent)
                )
            case .contributions:
                ContributionsWidgetContent(activity: insights.activity(for: scope.id))
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

    private var sessionsStartedToday: Int {
        let today = Calendar.current.startOfDay(for: .now)
        let sessions = scope.id.map { id in store.sessions.filter { $0.projectID == id } } ?? store.sessions
        return sessions.filter { Calendar.current.startOfDay(for: $0.createdAt) == today }.count
    }
}

/// `.accessibilityAction(named:)` is chained, not built from an array, so a
/// variable-length set of actions (one per supported size, plus the fixed
/// ones) goes through a small loop with `AnyView` erasure instead.
private struct HomeWidgetAccessibilityActionsModifier: ViewModifier {
    let kind: HomeWidgetKind
    let sizeLabel: (HomeWidgetSize) -> String
    let onResize: (HomeWidgetSize) -> Void
    let onMoveEarlier: () -> Void
    let onMoveLater: () -> Void
    let onRemove: () -> Void
    let onEditSettings: (() -> Void)?

    func body(content: Content) -> some View {
        var view = AnyView(content)
        for candidate in kind.supportedSizes {
            view = AnyView(view.accessibilityAction(named: Text("Size: \(sizeLabel(candidate))")) { onResize(candidate) })
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
