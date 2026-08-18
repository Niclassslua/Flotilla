import SwiftUI
import AppKit
import SessionKit
import GitKit
import DesignSystem
import SettingsKit

public enum ProjectWorkspaceMode: String, CaseIterable, Identifiable {
    case overview
    case worktrees
    case pipeline
    case context

    public var id: Self { self }

    public var title: String {
        switch self {
        case .overview: "Overview & Ops"
        case .worktrees: "Git & Worktrees"
        case .pipeline: "Kanban Pipeline"
        case .context: "Context & Rules"
        }
    }

    public var systemImage: String {
        switch self {
        case .overview: "bolt.horizontal.fill"
        case .worktrees: "arrow.triangle.branch"
        case .pipeline: "square.grid.3x2"
        case .context: "doc.badge.gearshape"
        }
    }
}

struct ProjectsWorkspaceView: View {
    @Bindable var store: AppStore
    @Binding var selectedProjectID: UUID?
    let openSession: (UUID) -> Void
    let terminalManager: TerminalManager
    let openCodeSubscription: OpenCodeSubscription

    @State private var searchText = ""
    @State private var selectedMode: ProjectWorkspaceMode = .overview
    @State private var projectSheet: ProjectSheet?

    init(
        store: AppStore,
        selectedProjectID: Binding<UUID?>,
        openSession: @escaping (UUID) -> Void,
        terminalManager: TerminalManager,
        openCodeSubscription: OpenCodeSubscription = .none
    ) {
        self.store = store
        self._selectedProjectID = selectedProjectID
        self.openSession = openSession
        self.terminalManager = terminalManager
        self.openCodeSubscription = openCodeSubscription
    }

    private enum ProjectSheet: String, Identifiable {
        case add
        case importWorkspace

        var id: Self { self }
    }

    private var filteredProjects: [Project] {
        guard !searchText.isEmpty else { return store.projects }
        return store.projects.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.rootPath.path.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var selectedProject: Project? {
        store.projects.first { $0.id == selectedProjectID }
    }

    var body: some View {
        Group {
            if let selectedProject {
                NavigationSplitView {
                    List(filteredProjects, selection: $selectedProjectID) { project in
                        let sessions = store.sessions(for: project)
                        let activeCount = sessions.filter { $0.status == .working || $0.status == .waitingForInput }.count
                        HStack(spacing: FlotillaSpacing.small) {
                            ProjectMark(title: project.name, tint: ProjectMark.tint(for: project))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name)
                                    .font(FlotillaTypography.headline)
                                HStack(spacing: 4) {
                                    Text("\(sessions.count) sessions")
                                        .font(FlotillaTypography.caption)
                                        .foregroundStyle(FlotillaColors.textSecondary)
                                    if activeCount > 0 {
                                        Text("• \(activeCount) active")
                                            .font(FlotillaTypography.caption.weight(.semibold))
                                            .foregroundStyle(FlotillaColors.statusWorking)
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 3)
                        .tag(project.id)
                        .accessibilityIdentifier("ProjectRow-\(project.name)")
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .background(FlotillaColors.sidebar)
                    .searchable(text: $searchText, placement: .sidebar, prompt: "Search projects…")
                    .safeAreaInset(edge: .top, spacing: 0) { projectSidebarHeader }
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
                } detail: {
                    ProjectWorkspaceDetail(
                        project: selectedProject,
                        sessions: store.sessions(for: selectedProject),
                        selectedMode: $selectedMode,
                        store: store,
                        terminalManager: terminalManager,
                        openSession: openSession,
                        openCodeSubscription: openCodeSubscription,
                        onBackToGrid: { selectedProjectID = nil }
                    )
                    .id(selectedProject.id)
                }
            } else {
                ProjectsCommandCenterView(
                    store: store,
                    onSelect: { selectedProjectID = $0 },
                    onAdd: { projectSheet = .add },
                    onImportWorkspace: { projectSheet = .importWorkspace },
                    onQuickLaunch: { project in
                        selectedProjectID = project.id
                        selectedMode = .overview
                    }
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(FlotillaColors.canvas)
        .sheet(item: $projectSheet) { sheet in
            ProjectPathSheet(importsWorkspace: sheet == .importWorkspace) { paths in
                for path in paths { store.addProject(at: path) }
                projectSheet = nil
            }
        }
    }

    private var projectSidebarHeader: some View {
        HStack(alignment: .center, spacing: FlotillaSpacing.small) {
            VStack(alignment: .leading, spacing: 1) {
                Text("PROJECTS")
                    .font(FlotillaTypography.caption2.weight(.bold))
                    .tracking(0.9)
                    .foregroundStyle(FlotillaColors.accent)
                Text("\(store.projects.count) workspaces")
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textSecondary)
            }
            Spacer()
            Button {
                selectedProjectID = nil
            } label: {
                Image(systemName: "square.grid.2x2")
            }
            .buttonStyle(.plain)
            .help("All projects")

            Button {
                projectSheet = .add
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("Add project")
            .accessibilityIdentifier("Projects.ImportButton")
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
        .background(FlotillaColors.sidebar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - Projects Command Center (Top-Level Multi-Repo Dashboard)

struct ProjectsCommandCenterView: View {
    @Bindable var store: AppStore
    let onSelect: (UUID) -> Void
    let onAdd: () -> Void
    let onImportWorkspace: () -> Void
    let onQuickLaunch: (Project) -> Void

    @State private var searchText = ""
    @State private var sortOrder: ProjectSort = .active
    @State private var filterMode: ProjectFilter = .all

    init(
        store: AppStore,
        onSelect: @escaping (UUID) -> Void,
        onAdd: @escaping () -> Void,
        onImportWorkspace: @escaping () -> Void,
        onQuickLaunch: @escaping (Project) -> Void
    ) {
        self.store = store
        self.onSelect = onSelect
        self.onAdd = onAdd
        self.onImportWorkspace = onImportWorkspace
        self.onQuickLaunch = onQuickLaunch
    }

    private enum ProjectSort: String, CaseIterable, Identifiable {
        case active = "Active"
        case recent = "Last Used"
        case name = "Name"

        var id: Self { self }
    }

    private enum ProjectFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case activeOnly = "Active Agents"
        case attention = "Needs Attention"

        var id: Self { self }
    }

    private var activeSessionsCount: Int {
        store.sessions.filter { $0.status == .working || $0.status == .waitingForInput }.count
    }

    private var attentionSessions: [Session] {
        store.sessions.filter { $0.status == .waitingForInput || $0.status == .crashed }
    }

    private var filteredProjects: [Project] {
        var list = store.projects
        if !searchText.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                    || $0.rootPath.path.localizedCaseInsensitiveContains(searchText)
            }
        }
        switch filterMode {
        case .all:
            break
        case .activeOnly:
            list = list.filter { project in
                store.sessions(for: project).contains { $0.status == .working || $0.status == .waitingForInput }
            }
        case .attention:
            list = list.filter { project in
                store.sessions(for: project).contains { $0.status == .waitingForInput || $0.status == .crashed }
            }
        }
        switch sortOrder {
        case .active:
            return list.sorted {
                let countA = store.sessions(for: $0).filter { $0.status == .working || $0.status == .waitingForInput }.count
                let countB = store.sessions(for: $1).filter { $0.status == .working || $0.status == .waitingForInput }.count
                if countA != countB { return countA > countB }
                return store.sessions(for: $0).count > store.sessions(for: $1).count
            }
        case .recent:
            return list.sorted {
                let lastA = store.sessions(for: $0).map(\.lastActiveAt).max() ?? Date.distantPast
                let lastB = store.sessions(for: $1).map(\.lastActiveAt).max() ?? Date.distantPast
                return lastA > lastB
            }
        case .name:
            return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FlotillaSpacing.xLarge) {
                heroHeader
                fleetMetricStrip
                if !attentionSessions.isEmpty {
                    attentionQueueBanner
                }
                controlsAndFilterBar
                projectsGridSection
            }
            .padding(FlotillaSpacing.xxLarge)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(FlotillaColors.canvas)
        .accessibilityIdentifier("Projects.CommandCenter")
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: FlotillaSpacing.small) {
                    Image(systemName: "folder.fill.badge.gearshape")
                        .font(.system(size: FlotillaIconSize.large))
                        .foregroundStyle(FlotillaColors.accent)
                    Text("Projects Fleet")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(FlotillaColors.textPrimary)
                }
                Text("Orchestrate multi-agent coding sessions, isolated git worktrees, and codebase rules across your repositories.")
                    .font(FlotillaTypography.callout)
                    .foregroundStyle(FlotillaColors.textSecondary)
            }
            Spacer()
            HStack(spacing: FlotillaSpacing.small) {
                Button(action: onImportWorkspace) {
                    Label("Import Workspace", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                Button(action: onAdd) {
                    Label("Add Project", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(FlotillaColors.accent)
            }
        }
    }

    // MARK: - Fleet Metric Strip

    private var fleetMetricStrip: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            metricCard(
                title: "REPOSITORIES",
                value: "\(store.projects.count)",
                icon: "folder",
                tint: FlotillaColors.textPrimary
            )
            metricCard(
                title: "ACTIVE AGENTS",
                value: "\(activeSessionsCount)",
                icon: "bolt.fill",
                tint: activeSessionsCount > 0 ? FlotillaColors.statusWorking : FlotillaColors.textSecondary
            )
            metricCard(
                title: "NEEDS ATTENTION",
                value: "\(attentionSessions.count)",
                icon: attentionSessions.isEmpty ? "checkmark.circle" : "exclamationmark.triangle.fill",
                tint: attentionSessions.isEmpty ? FlotillaColors.statusWorking : FlotillaColors.statusWaitingForInput
            )
            metricCard(
                title: "TOTAL SESSIONS",
                value: "\(store.sessions.count)",
                icon: "terminal",
                tint: FlotillaColors.accent
            )
        }
        .accessibilityIdentifier("Projects.MetricStrip")
    }

    private func metricCard(title: String, value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: FlotillaSpacing.medium) {
            Image(systemName: icon)
                .font(.system(size: FlotillaIconSize.large))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: FlotillaRadius.control))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(FlotillaTypography.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(FlotillaColors.textTertiary)
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(FlotillaColors.textPrimary)
            }
            Spacer(minLength: 0)
        }
        .padding(FlotillaSpacing.medium)
        .frame(maxWidth: .infinity)
        .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.card)
                .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.thin)
        }
    }

    // MARK: - Attention Queue Banner

    private var attentionQueueBanner: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            HStack(spacing: FlotillaSpacing.small) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(FlotillaColors.statusWaitingForInput)
                Text("\(attentionSessions.count) agent session\(attentionSessions.count == 1 ? "" : "s") require your attention")
                    .font(FlotillaTypography.headline)
                    .foregroundStyle(FlotillaColors.textPrimary)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: FlotillaSpacing.small) {
                    ForEach(attentionSessions) { session in
                        Button {
                            if let project = store.project(for: session) {
                                onSelect(project.id)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                StatusBadge(session.status, size: .micro, showLabel: false)
                                Text(session.title)
                                    .font(FlotillaTypography.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text("(\(session.agent.displayName))")
                                    .font(FlotillaTypography.caption)
                                    .foregroundStyle(FlotillaColors.textSecondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(FlotillaColors.surfaceElevated, in: Capsule())
                            .overlay {
                                Capsule().strokeBorder(FlotillaColors.statusWaitingForInput.opacity(0.4))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(FlotillaSpacing.medium)
        .background(FlotillaColors.statusWaitingForInput.opacity(0.1), in: RoundedRectangle(cornerRadius: FlotillaRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.card)
                .strokeBorder(FlotillaColors.statusWaitingForInput.opacity(0.3))
        }
    }

    // MARK: - Filter & Controls Bar

    private var controlsAndFilterBar: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(FlotillaColors.textTertiary)
                TextField("Filter projects by name or path…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(FlotillaTypography.body)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: 320)
            .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.control))
            .overlay {
                RoundedRectangle(cornerRadius: FlotillaRadius.control)
                    .strokeBorder(FlotillaColors.separator)
            }

            Picker("Filter", selection: $filterMode) {
                ForEach(ProjectFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)

            Spacer()

            HStack(spacing: 5) {
                Text("SORT")
                    .font(FlotillaTypography.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(FlotillaColors.textTertiary)
                ForEach(ProjectSort.allCases) { option in
                    Button(option.rawValue) { sortOrder = option }
                        .buttonStyle(.plain)
                        .font(FlotillaTypography.caption.weight(sortOrder == option ? .semibold : .regular))
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(
                            sortOrder == option ? FlotillaColors.surfaceElevated : .clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .foregroundStyle(sortOrder == option ? FlotillaColors.textPrimary : FlotillaColors.textSecondary)
                }
            }
        }
    }

    // MARK: - Projects Grid

    private var projectsGridSection: some View {
        Group {
            if filteredProjects.isEmpty {
                ContentUnavailableView(
                    "No Matching Projects",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Try adjusting your search query or filter.")
                )
                .frame(maxWidth: .infinity, minHeight: 280)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: FlotillaSpacing.large)], spacing: FlotillaSpacing.large) {
                    ForEach(filteredProjects) { project in
                        ProjectCommandCard(
                            project: project,
                            sessions: store.sessions(for: project),
                            gitService: store.gitService,
                            diffStatStore: store.diffStatStore,
                            onSelect: { onSelect(project.id) },
                            onQuickLaunch: { onQuickLaunch(project) },
                            onRemove: { store.removeProject(id: project.id) }
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Project Workspace Detail

struct ProjectWorkspaceDetail: View {
    let project: Project
    let sessions: [Session]
    @Binding var selectedMode: ProjectWorkspaceMode
    @Bindable var store: AppStore
    let terminalManager: TerminalManager
    let openSession: (UUID) -> Void
    let openCodeSubscription: OpenCodeSubscription
    let onBackToGrid: () -> Void

    @State private var currentBranch: String?
    @State private var projectDiffStat: GitDiffStat?

    var body: some View {
        VStack(spacing: 0) {
            projectHeader
            Divider()
            Group {
                switch selectedMode {
                case .overview:
                    ProjectOverviewView(
                        project: project,
                        sessions: sessions,
                        store: store,
                        openSession: openSession,
                        openCodeSubscription: openCodeSubscription
                    )
                case .worktrees:
                    ProjectWorktreeMatrixView(
                        project: project,
                        sessions: sessions,
                        store: store,
                        openSession: openSession
                    )
                case .pipeline:
                    ProjectKanbanPipelineView(
                        project: project,
                        store: store,
                        terminalManager: terminalManager,
                        openSession: openSession
                    )
                case .context:
                    ProjectContextStudioView(
                        project: project,
                        store: store
                    )
                }
            }
            .id(selectedMode)
        }
        .task(id: project.id) {
            if let branch = try? await store.gitService.currentBranch(at: project.rootPath) {
                currentBranch = branch
            }
            if let stat = try? await store.gitService.diffStat(at: project.rootPath) {
                projectDiffStat = stat
            }
        }
    }

    private var projectHeader: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
            HStack(alignment: .center, spacing: FlotillaSpacing.medium) {
                ProjectMark(title: project.name, tint: ProjectMark.tint(for: project))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: FlotillaSpacing.small) {
                        Text(project.name)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(FlotillaColors.textPrimary)

                        if let branch = currentBranch {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: FlotillaIconSize.small))
                                Text(branch)
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(FlotillaColors.surfaceElevated, in: Capsule())
                            .foregroundStyle(FlotillaColors.textSecondary)
                        }

                        if let stat = projectDiffStat, !stat.isEmpty {
                            HStack(spacing: 4) {
                                if stat.additions > 0 {
                                    Text("+\(stat.additions)").foregroundStyle(FlotillaColors.statusWorking)
                                }
                                if stat.deletions > 0 {
                                    Text("-\(stat.deletions)").foregroundStyle(FlotillaColors.statusCrashed)
                                }
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(FlotillaColors.surfaceElevated, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }

                    Text(project.rootPath.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                HStack(spacing: FlotillaSpacing.small) {
                    Button {
                        selectedMode = .overview
                    } label: {
                        Label("New Session", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FlotillaColors.accent)

                    Button {
                        openInEditor()
                    } label: {
                        Label("Editor", systemImage: "curlybraces")
                    }
                    .buttonStyle(.bordered)
                    .help("Open in VS Code or Cursor")

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([project.rootPath])
                    } label: {
                        Label("Reveal", systemImage: "finder")
                    }
                    .buttonStyle(.bordered)
                }
            }

            Picker("Project Workspace Mode", selection: $selectedMode) {
                ForEach(ProjectWorkspaceMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 620)
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.medium)
        .background(FlotillaColors.surface)
    }

    private func openInEditor() {
        if let vscodeURL = URL(string: "vscode://file\(project.rootPath.path)") {
            if NSWorkspace.shared.open(vscodeURL) { return }
        }
        if let cursorURL = URL(string: "cursor://file\(project.rootPath.path)") {
            if NSWorkspace.shared.open(cursorURL) { return }
        }
        NSWorkspace.shared.open(project.rootPath)
    }
}

// MARK: - Project Overview & Ops Hub (Design 1)

private struct ProjectOverviewView: View {
    let project: Project
    let sessions: [Session]
    @Bindable var store: AppStore
    let openSession: (UUID) -> Void
    let openCodeSubscription: OpenCodeSubscription

    @State private var goal = ""
    @State private var agent: AgentKind = .claudeCode
    @State private var model = ""
    @State private var effort: AgentEffort = .medium
    @State private var useWorktree = true
    @State private var isLaunching = false

    init(
        project: Project,
        sessions: [Session],
        store: AppStore,
        openSession: @escaping (UUID) -> Void,
        openCodeSubscription: OpenCodeSubscription = .none
    ) {
        self.project = project
        self.sessions = sessions
        self.store = store
        self.openSession = openSession
        self.openCodeSubscription = openCodeSubscription
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FlotillaSpacing.xLarge) {
                quickLaunch
                sessionsSection
                worktreesSection
            }
            .padding(FlotillaSpacing.xxLarge)
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var quickLaunch: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
            HStack(spacing: FlotillaSpacing.small) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(FlotillaColors.accent)
                Text("Start something new")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(FlotillaColors.textPrimary)
            }

            TextEditor(text: $goal)
                .font(FlotillaTypography.body)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 88)
                .background(FlotillaColors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.card))
                .overlay {
                    RoundedRectangle(cornerRadius: FlotillaRadius.card)
                        .strokeBorder(FlotillaColors.separator)
                }

            HStack {
                Picker("Agent", selection: $agent) {
                    ForEach(AgentKind.allCases) { Text($0.displayName).tag($0) }
                }
                .frame(width: 150)

                ModelPickerView(agent: agent, openCodeSubscription: openCodeSubscription, model: $model)
                EffortLevelPicker(agent: agent, model: model, effort: $effort)

                Toggle("New worktree", isOn: $useWorktree)
                    .toggleStyle(.switch)

                Spacer()

                if isLaunching { ProgressView().controlSize(.small) }

                Button("Start Session", action: launch)
                    .buttonStyle(.borderedProminent)
                    .tint(FlotillaColors.accent)
                    .disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLaunching)
            }
        }
        .padding(FlotillaSpacing.large)
        .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.panel)
                .strokeBorder(FlotillaColors.separator)
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
            HStack {
                Text("Sessions")
                    .font(.title3.weight(.semibold))
                Text("\(sessions.count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textSecondary)
            }

            if sessions.isEmpty {
                Text("No agents have worked in this project yet.")
                    .font(FlotillaTypography.callout)
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .padding(.vertical, FlotillaSpacing.small)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: FlotillaSpacing.medium)], spacing: FlotillaSpacing.medium) {
                    ForEach(sessions) { session in
                        Button {
                            openSession(session.id)
                        } label: {
                            ProjectSessionCard(session: session, diffStatStore: store.diffStatStore)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var worktreesSection: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            Text("Worktrees")
                .font(.title3.weight(.semibold))

            let worktreeSessions = sessions.filter { $0.worktree != nil }
            if worktreeSessions.isEmpty {
                Text("No isolated worktrees yet.")
                    .font(FlotillaTypography.callout)
                    .foregroundStyle(FlotillaColors.textSecondary)
            } else {
                ForEach(worktreeSessions) { session in
                    HStack(spacing: FlotillaSpacing.small) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(FlotillaColors.accent)
                        Text(session.worktree?.branchName ?? "")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                        Spacer()
                        Text(session.worktree?.worktreePath.path ?? "")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(FlotillaColors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(FlotillaSpacing.small)
                    .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.control))
                }
            }
        }
    }

    private func launch() {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else { return }
        isLaunching = true
        Task {
            await store.createSession(
                title: String(trimmedGoal.prefix(60)),
                goal: trimmedGoal,
                agent: agent,
                model: model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : model,
                effort: agent.supportsEffortSelection ? effort : nil,
                projectFolder: project.rootPath,
                checkoutMode: useWorktree ? .newWorktree : .mainCheckout
            )
            isLaunching = false
            if store.lastCreationError == nil, let id = store.selectedSessionID {
                goal = ""
                openSession(id)
            }
        }
    }
}

// MARK: - Project Session Card

private struct ProjectSessionCard: View {
    let session: Session
    let diffStatStore: DiffStatStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StatusBadge(session.status, size: .micro, showLabel: false)
                Text(StatusPresentation.label(for: session.status))
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textSecondary)
                Spacer()
                SessionDiffStatView(session: session, diffStatStore: diffStatStore)
                Text(session.agent.displayName)
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
            Text(session.title)
                .font(FlotillaTypography.headline)
                .foregroundStyle(FlotillaColors.textPrimary)
                .lineLimit(1)
            Text(session.goal)
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textSecondary)
                .lineLimit(2)
                .frame(minHeight: 28, alignment: .top)
        }
        .padding(FlotillaSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.card))
        .overlay { RoundedRectangle(cornerRadius: FlotillaRadius.card).strokeBorder(FlotillaColors.separator) }
    }
}

// MARK: - Project Path Sheet

private struct ProjectPathSheet: View {
    @Environment(\.dismiss) private var dismiss

    let importsWorkspace: Bool
    let addPaths: ([URL]) -> Void
    @State private var path = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: importsWorkspace ? "square.stack.3d.down.right" : "folder.badge.plus")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(FlotillaColors.accent)
                    .frame(width: 40, height: 40)
                    .background(FlotillaColors.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 3) {
                    Text(importsWorkspace ? "Import a workspace" : "Add a project")
                        .font(.title3.weight(.semibold))
                    Text(importsWorkspace
                         ? "Scan one folder for local Git projects and add them together."
                         : "Add a local checkout to your Flotilla project library.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(importsWorkspace ? "Workspace path" : "Path")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField(importsWorkspace ? "/path/to/workspace" : "/path/to/project", text: $path)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button("Browse…", action: browse)
                }
                if importsWorkspace {
                    Text("Immediate child folders containing a .git directory or file will be imported.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(20)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(importsWorkspace ? "Scan" : "Add Project") {
                    addPaths(resolvedPaths)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || resolvedPaths.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 520)
        .background(FlotillaColors.surface)
    }

    private var resolvedPaths: [URL] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let root = URL(fileURLWithPath: trimmed).standardizedFileURL
        guard importsWorkspace else { return [root] }
        fileScanLog.notice("resolvedPaths: listing immediate children of \(root.path, privacy: .public)")
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return children.filter { child in
            guard !WorkspaceFileService.isTCCProtected(child) else { return false }
            var isDirectory: ObjCBool = false
            let gitPath = child.appendingPathComponent(".git").path
            return FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
                && FileManager.default.fileExists(atPath: gitPath)
        }
    }

    private func browse() {
        if ProcessInfo.processInfo.environment["UI_TESTING"] == "1" {
            path = AppEnvironment.uiTestFixtureProjectPath.path
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = importsWorkspace ? "Choose Workspace" : "Choose Project"
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}
