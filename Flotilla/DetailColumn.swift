import SwiftUI
import SessionKit
import DesignSystem
import TerminalKit
import GitKit

struct DetailColumn: View {
    @Bindable var store: AppStore
    @Bindable var navigator: WorkspaceNavigator
    @Bindable var settingsViewModel: SettingsViewModel
    let terminalManager: TerminalManager
    let workspaceRegistry: SessionWorkspaceRegistry
    let activityStore: SessionActivityStore
    let onOpenSession: (UUID) -> Void
    let onOpenProject: (UUID) -> Void
    let onCreateSession: () -> Void

    /// Which grid tile has keyboard focus. Previously passed as
    /// `.constant(nil)`, which meant no tile could ever become active.
    @State private var activeGridSessionID: UUID?

    var body: some View {
        Group {
            switch navigator.selection {
            case .overview:
                overviewContent
            case .allSessions:
                sessionsContent(showingAll: true)
            case .allProjects:
                projectsContent
            case .project(let projectID):
                projectContent(projectID: projectID)
            case .session(let sessionID):
                sessionContent(sessionID: sessionID)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { banners }
        .toolbar {
            WorkspaceToolbar(
                navigator: navigator,
                store: store,
                settingsViewModel: settingsViewModel,
                onCommandPalette: { navigator.presentedSheet = .commandPalette },
                onInspectorToggle: { navigator.isInspectorOpen.toggle() }
            )
        }
        .navigationTitle(scopeTitle)
        .navigationSubtitle(scopeSubtitle)
        .background(FlotillaColors.canvas)
        .inspector(isPresented: $navigator.isInspectorOpen) {
            if let session = store.selectedSession {
                WorkspaceInspector(
                    registry: workspaceRegistry,
                    session: session,
                    tab: $navigator.inspectorTab,
                    store: store
                )
                .inspectorColumnWidth(min: 280, ideal: 360, max: 520)
            }
        }
    }

    @ViewBuilder
    private var overviewContent: some View {
        HomeDashboardView(
            store: store,
            openProject: onOpenProject,
            openSession: onOpenSession,
            settingsViewModel: settingsViewModel,
            activityStore: activityStore,
            openCodeSubscription: settingsViewModel.settings.openCodeSubscription,
            defaultAgent: .claudeCode
        )
    }

    @ViewBuilder
    private func sessionsContent(showingAll: Bool) -> some View {
        switch navigator.presentation {
        case .focus:
            focusedSessionContent
case .grid:
            GridView(
                store: store,
                terminalManager: terminalManager,
                activeSessionID: $activeGridSessionID,
                openSession: onOpenSession,
                settingsViewModel: settingsViewModel
            )
        case .board:
            KanbanTabView(
                store: store,
                terminalManager: terminalManager,
                openSession: onOpenSession
            )
        case .list:
            listView
        }
    }

    @ViewBuilder
    private var focusedSessionContent: some View {
        if let session = store.selectedSession {
            VStack(spacing: 0) {
                sessionSurface(for: session)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            EmptyWorkspaceView(
                hasSessions: !store.sessions.isEmpty,
                onCreate: onCreateSession
            )
            .accessibilityIdentifier("DetailPlaceholder")
        }
    }

    @ViewBuilder
    private func sessionSurface(for session: Session) -> some View {
        switch navigator.sessionLens {
        case .terminal:
            terminal(for: session)
        case .files:
            FileBrowserView(rootURL: workspaceRoot(for: session))
        case .instructions:
            RulesPanelView(rootURL: workspaceRoot(for: session), filter: .all)
        }
    }

    @ViewBuilder
    private func terminal(for session: Session) -> some View {
        if let process = store.process(for: session.id) {
            TerminalHostView(
                controller: terminalManager.controller(
                    for: session,
                    process: process,
                    scrollback: store.scrollback(for: session.id),
                    outputHandler: { data in
                        store.appendTerminalOutput(data, toSessionID: session.id)
                    },
                    inputHandler: {}
                ),
                presentation: .session,
                isFocused: true
            )
            .id(session.id)
            .background(FlotillaColors.terminalCanvas)
        } else {
            ContentUnavailableView {
                Label(
                    session.status == .crashed ? "Agent Stopped" : "Session Not Running",
                    systemImage: session.status == .crashed ? "exclamationmark.triangle" : "terminal"
                )
            } description: {
                Text("Check the agent executable in Settings, then restart this interactive session.")
            } actions: {
                Button("Restart Session") {
                    store.restartSession(sessionID: session.id)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("Restart Session")
            }
            .accessibilityIdentifier("TerminalPlaceholder")
        }
    }

    @ViewBuilder
    private func projectContent(projectID: UUID) -> some View {
        if let project = store.projects.first(where: { $0.id == projectID }) {
            VStack(spacing: 0) {
                projectHeader(project)
                Divider()

                switch navigator.presentation {
case .grid:
                    GridView(
                        store: store,
                        terminalManager: terminalManager,
                        activeSessionID: $activeGridSessionID,
                        openSession: onOpenSession,
                        projectFilter: projectID,
                        settingsViewModel: settingsViewModel
                    )
                case .board:
                    KanbanTabView(
                        store: store,
                        terminalManager: terminalManager,
                        openSession: onOpenSession
                    )
                case .list:
                    projectListView(project)
                case .focus:
                    if let session = store.sessions(for: project).first {
                        sessionSurface(for: session)
                    } else {
                        EmptyWorkspaceView(hasSessions: false, onCreate: onCreateSession)
                    }
                }
            }
        } else {
            ContentUnavailableView("Project Not Found", systemImage: "folder.badge.questionmark")
        }
    }

    @ViewBuilder
    private func projectHeader(_ project: Project) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title2)
                .foregroundStyle(FlotillaColors.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.title2.weight(.semibold))
                Text(project.rootPath.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([project.rootPath])
            } label: {
                Label("Reveal", systemImage: "finder")
            }
            Button {
                onCreateSession()
            } label: {
                Label("New Session", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private func projectListView(_ project: Project) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Sessions")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 22)

                let sessions = store.sessions(for: project)
                if sessions.isEmpty {
                    Text("No agents have worked in this project yet.")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 22)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                        ForEach(sessions) { session in
                            Button {
                                onOpenSession(session.id)
                            } label: {
                                SessionCard(
                                    session: session,
                                    variant: .tile,
                                    diffStatStore: store.diffStatStore,
                                    activityStore: nil,
                                    isSelected: false,
                                    isActive: false,
                                    onTap: { onOpenSession(session.id) },
                                    onDelete: {},
                                    onRestart: {},
                                    onRevealInFinder: {},
                                    onCopyPath: {},
                                    onCopyBranch: {},
                                    terminal: { EmptyView() }
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 22)
                }
            }
            .padding(.vertical, 22)
        }
        .background(FlotillaColors.canvas)
    }

    @ViewBuilder
    private var projectsContent: some View {
        ProjectCollectionView(
            projects: store.projects,
            sessionCount: { store.sessions(for: $0).count },
            select: onOpenProject,
            add: { navigator.presentedSheet = .createSession },
            importWorkspace: { navigator.presentedSheet = .createSession }
        )
    }

    @ViewBuilder
    private func sessionContent(sessionID: UUID) -> some View {
        if let session = store.sessions.first(where: { $0.id == sessionID }) {
            VStack(spacing: 0) {
                sessionSurface(for: session)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            EmptyWorkspaceView(hasSessions: !store.sessions.isEmpty, onCreate: onCreateSession)
        }
    }

    @ViewBuilder
    private var listView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(store.sessions) { session in
                    Button {
                        onOpenSession(session.id)
                    } label: {
                        SessionCard(
                            session: session,
                            variant: .row,
                            diffStatStore: store.diffStatStore,
                            activityStore: nil,
                            isSelected: store.selectedSessionID == session.id,
                            onTap: { onOpenSession(session.id) },
                            onDelete: {},
                            onRestart: {},
                            onRevealInFinder: {},
                            onCopyPath: {},
                            onCopyBranch: {},
                            terminal: { EmptyView() }
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(22)
        }
        .background(FlotillaColors.canvas)
    }

    private var scopeTitle: String {
        switch navigator.selection {
        case .overview: return "Overview"
        case .allSessions: return "Sessions"
        case .allProjects: return "Projects"
        case .project(let id):
            return store.projects.first(where: { $0.id == id })?.name ?? "Project"
        case .session(let id):
            return store.sessions.first(where: { $0.id == id })?.title ?? "Session"
        }
    }

    private var scopeSubtitle: String {
        switch navigator.selection {
        case .overview:
            return HomeFleetStats(sessions: store.sessions).summary
        case .allSessions:
            let working = store.sessions.filter { $0.status == .working }.count
            let needsInput = store.sessions.filter { $0.status == .waitingForInput }.count
            let ready = store.sessions.filter { $0.status == .ready }.count
            return "\(working) working · \(needsInput) need input · \(ready) ready"
        case .allProjects:
            return "\(store.projects.count) projects"
        case .project(let id):
            let sessions = store.sessions.filter { $0.projectID == id }
            let working = sessions.filter { $0.status == .working }.count
            let needsInput = sessions.filter { $0.status == .waitingForInput }.count
            return "\(sessions.count) sessions · \(working) working · \(needsInput) need input"
        case .session(let id):
            guard let session = store.sessions.first(where: { $0.id == id }),
                  let project = store.project(for: session) else { return "" }
            return "\(project.name) · \(session.agent.displayName) · \(session.worktree?.branchName ?? session.agent.displayName)"
        }
    }

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 0) {
            if let warning = store.lastOperationError {
                OperationErrorBanner(message: warning) {
                    store.lastOperationError = nil
                }
            }
        }
    }

    private func workspaceRoot(for session: Session) -> URL {
        session.worktree?.worktreePath ?? session.workingDirectory
    }
}

private struct ProjectCollectionView: View {
    let projects: [Project]
    let sessionCount: (Project) -> Int
    let select: (UUID) -> Void
    let add: () -> Void
    let importWorkspace: () -> Void

    @State private var sortOrder = ProjectSort.recent

    private enum ProjectSort: String, CaseIterable, Identifiable {
        case recent = "Last used"
        case name = "Name"
        case active = "Active"

        var id: Self { self }
    }

    private var sortedProjects: [Project] {
        switch sortOrder {
        case .recent: projects
        case .name: projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .active: projects.sorted { sessionCount($0) > sessionCount($1) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your Projects")
                            .font(.system(size: 22, weight: .semibold))
                        Text("Jump back into a codebase or start an agent in a fresh context.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: importWorkspace) {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    Button(action: add) {
                        Label("Add Project", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if projects.isEmpty {
                    ContentUnavailableView(
                        "No Projects",
                        systemImage: "folder.badge.plus",
                        description: Text("Import a Git checkout or create a project-scoped session.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    HStack(spacing: 5) {
                        Text("SORT")
                            .font(.caption2.weight(.bold))
                            .tracking(0.8)
                            .foregroundStyle(.tertiary)
                        ForEach(ProjectSort.allCases) { option in
                            Button(option.rawValue) { sortOrder = option }
                                .buttonStyle(.plain)
                                .font(.caption.weight(sortOrder == option ? .semibold : .regular))
                                .padding(.horizontal, 9)
                                .frame(height: 26)
                                .background(
                                    sortOrder == option ? FlotillaColors.surfaceElevated : .clear,
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                                .foregroundStyle(sortOrder == option ? .primary : .secondary)
                        }
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                        ForEach(sortedProjects) { project in
                            Button {
                                select(project.id)
                            } label: {
                                ProjectCollectionCard(project: project, sessionCount: sessionCount(project))
                            }
                            .buttonStyle(.plain)
                            // This grid is the detail column, not the sidebar —
                            // the "Sidebar." prefix was a mislabel, and it left
                            // the Projects destination with no "ProjectRow-"
                            // element for tests to reach.
                            .accessibilityIdentifier(AXID.projectRow.rawValue + project.name)
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(FlotillaColors.canvas)
    }
}

struct ProjectCollectionCard: View {
    let project: Project
    let sessionCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(FlotillaColors.accent.opacity(0.12))
                    Image(systemName: "folder.fill")
                        .foregroundStyle(FlotillaColors.accent)
                }
                .frame(width: 32, height: 32)
                Spacer()
                Menu {
                    Button("Open") { }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([project.rootPath])
                    }
                    Button("New Session Here") { }
                    Divider()
                    Button("Remove Project", role: .destructive) { }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
            }
            Text(project.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(project.rootPath.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Divider()
            HStack {
                Label("\(sessionCount) session\(sessionCount == 1 ? "" : "s")", systemImage: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(sessionCount > 0 ? "Active" : "Ready")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(sessionCount > 0 ? FlotillaColors.statusWorking : .secondary)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .leading)
        .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(FlotillaColors.separator)
        }
        .contentShape(.rect)
    }
}

struct EmptyWorkspaceView: View {
    let hasSessions: Bool
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 48, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(FlotillaColors.accent)
                .accessibilityHidden(true)
            VStack(spacing: 7) {
                Text(hasSessions ? "Choose a session" : "Your agents, in formation")
                    .font(.title2.weight(.semibold))
                Text(hasSessions
                    ? "Select an agent from the sidebar to open its live terminal and workspace."
                    : "Launch isolated coding sessions, watch their signals, and move between worktrees without losing context.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
            }
            Button(hasSessions ? "New Session" : "Launch First Session", action: onCreate)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlotillaColors.accent.opacity(0.025))
    }
}

struct OperationErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button("Dismiss", action: dismiss)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.09))
    }
}