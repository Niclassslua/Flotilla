import SwiftUI
import SessionKit
import DesignSystem
import TerminalKit

struct DetailColumn: View {
    @Environment(\.openSettings) private var openSettings
    @Bindable var store: AppStore
    @Bindable var navigator: WorkspaceNavigator
    @Bindable var settingsViewModel: SettingsViewModel
    @Bindable var startupCheck: StartupCheckViewModel
    let terminalManager: TerminalManager
    let activityStore: SessionActivityStore
    let onOpenSession: (UUID) -> Void
    let onOpenProject: (UUID) -> Void
    let onCreateSession: () -> Void
    let onCommandPalette: () -> Void

    @State private var activeGridSessionID: UUID?
    @State private var gitSidebarSessionID: UUID?

    var body: some View {
        let _ = navigator.presentedSheet
        Group {
            switch navigator.selection {
            case .overview:
                overviewContent
            case .allSessions, .smartList:
                sessionsContent
            case .project(let projectID):
                projectContent(projectID: projectID)
            case .session(let sessionID):
                sessionContent(sessionID: sessionID)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { banners }
        .navigationTitle(scopeTitle)
        .navigationSubtitle(scopeSubtitle)
        .background(FlotillaColors.canvas)
        .inspector(isPresented: gitSidebarPresented) {
            gitSidebarContent
                .inspectorColumnWidth(
                    min: FlotillaLayoutWidth.inspectorMin,
                    ideal: FlotillaLayoutWidth.inspectorIdeal,
                    max: FlotillaLayoutWidth.inspectorMax
                )
        }
        .onChange(of: activeGitSidebarSession?.id) { _, sessionID in
            guard gitSidebarSessionID != nil else { return }
            gitSidebarSessionID = sessionID
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
            terminalManager: terminalManager,
            openCodeSubscription: settingsViewModel.settings.openCodeSubscription,
            highlightUnseenCommits: settingsViewModel.settings.git.highlightUnseenCommits,
            defaultAgent: .claudeCode
        )
    }

    /// Every presentation reads one scope, so switching between them changes
    /// how the fleet is shown and never which sessions are in it.
    @ViewBuilder
    private var sessionsContent: some View {
        switch navigator.presentation {
        case .focus:
            focusedSessionContent
        case .grid:
            collection {
                GridView(
                    store: store,
                    terminalManager: terminalManager,
                    activeSessionID: $activeGridSessionID,
                    openSession: onOpenSession,
                    scope: navigator.sessionScope,
                    settingsViewModel: settingsViewModel
                )
            }
        case .board:
            collection {
                KanbanTabView(
                    store: store,
                    terminalManager: terminalManager,
                    activityStore: activityStore,
                    openSession: onOpenSession,
                    scope: navigator.sessionScope
                )
            }
        }
    }

    /// Both fleet presentations sit under the same group bar, so the group
    /// survives switching between them: scope decides *what* is on screen,
    /// presentation decides *how*.
    private func collection(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            SessionGroupBar(
                store: store,
                navigator: navigator,
                settingsViewModel: settingsViewModel,
                showsGridControls: navigator.presentation == .grid
            )
            Divider()
            content()
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

    /// The single place both focused paths (`.focus` presentation and a
    /// `.session` selection) build their content, so the bar cannot appear on
    /// one route and not the other.
    @ViewBuilder
    private func sessionSurface(for session: Session) -> some View {
        VStack(spacing: 0) {
            SessionBar(
                session: session,
                store: store,
                variant: .focus,
                actions: sessionBarActions(for: session)
            )
            Divider()
            terminal(for: session)
        }
    }

    /// Files and the full Changes workspace still land on the project scope.
    /// The first action now opens the compact, session-scoped Git inspector
    /// without unmounting the terminal beneath it.
    private func sessionBarActions(for session: Session) -> SessionBarActions {
        SessionBarActions(
            onRename: { store.renameSession(sessionID: session.id, newTitle: $0) },
            onToggleGitSidebar: {
                gitSidebarSessionID = gitSidebarSessionID == session.id ? nil : session.id
            },
            onBrowseFiles: { navigator.openProjectPanel(.files, scopedTo: session) },
            onReviewChanges: { navigator.openProjectPanel(.git, scopedTo: session) }
        )
    }

    private var activeGitSidebarSession: Session? {
        let session: Session? = switch navigator.selection {
        case .session(let sessionID):
            store.sessions.first { $0.id == sessionID }
        case .allSessions, .smartList:
            navigator.presentation == .focus ? store.selectedSession : nil
        case .overview, .project:
            nil
        }
        return session?.projectID == nil ? nil : session
    }

    private var gitSidebarPresented: Binding<Bool> {
        Binding(
            get: { gitSidebarSessionID != nil && activeGitSidebarSession != nil },
            set: { isPresented in
                gitSidebarSessionID = isPresented ? activeGitSidebarSession?.id : nil
            }
        )
    }

    @ViewBuilder
    private var gitSidebarContent: some View {
        if let sessionID = gitSidebarSessionID,
           let session = store.sessions.first(where: { $0.id == sessionID }),
           let project = store.project(for: session) {
            SessionGitSidebar(
                viewModel: navigator.sessionGitSidebarViewModel(
                    for: session,
                    gitService: store.gitService
                ),
                store: store,
                session: session,
                project: project,
                onClose: { gitSidebarSessionID = nil },
                onOpenCommit: { commit, branch in
                    navigator.openProjectCommit(
                        commit,
                        branch: branch,
                        scopedTo: session,
                        gitService: store.gitService
                    )
                    gitSidebarSessionID = nil
                }
            )
            .id(sessionID)
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
                    customReflowHandler: store.customReflowHandler(for: session.id),
                    onPTYResize: store.resizeHandler(for: session.id),
                    outputHandler: { data in
                        store.appendTerminalOutput(data, toSessionID: session.id)
                    },
                    inputHandler: {}
                ),
                presentation: .session,
                isFocused: true
            )
            .id(session.id)
            .accessibilityIdentifier("TerminalView-\(session.title)")
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
                .tint(FlotillaColors.accent)
                .accessibilityIdentifier("Restart Session")
            }
            .accessibilityIdentifier("TerminalPlaceholder")
        }
    }

    @ViewBuilder
    private func projectContent(projectID: UUID) -> some View {
        if let project = store.projects.first(where: { $0.id == projectID }) {
            ProjectDetailView(
                project: project,
                sessions: store.sessions(for: project),
                store: store,
                terminalManager: terminalManager,
                activityStore: activityStore,
                openSession: onOpenSession,
                openCodeSubscription: settingsViewModel.settings.openCodeSubscription,
                highlightUnseenCommits: settingsViewModel.settings.git.highlightUnseenCommits,
                createWorktreeByDefault: settingsViewModel.settings.sessionDefaults.createWorktreeByDefault,
                fetchBeforeCreatingWorktree: settingsViewModel.settings.git.fetchBeforeCreatingWorktree,
                defaultAgent: AgentKind(rawValue: settingsViewModel.settings.sessionDefaults.defaultAgentRawValue) ?? .claudeCode
            )
        } else {
            ContentUnavailableView("Project Not Found", systemImage: "folder.badge.questionmark")
        }
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

    private var scopeTitle: String {
        switch navigator.selection {
        case .overview: return "Home"
        case .allSessions: return "Sessions"
        case .smartList(let list): return list.title
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
            let ready = store.sessions.filter { $0.status == .readyForReview }.count
            return "\(working) working · \(needsInput) need input · \(ready) ready"
        case .smartList(let list):
            let matching = list.filter(store.sessions).count
            return "\(matching) of \(store.sessions.count) session\(store.sessions.count == 1 ? "" : "s")"
        case .project(let id):
            let sessions = store.sessions.filter { $0.projectID == id }
            let working = sessions.filter { $0.status == .working }.count
            let needsInput = sessions.filter { $0.status == .waitingForInput }.count
            return "\(sessions.count) sessions · \(working) working · \(needsInput) need input"
        case .session:
            // The session bar states this now, inside the workspace and next
            // to the terminal it describes. Repeating it in the subtitle put
            // the same four facts two points under the window title.
            return ""
        }
    }

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 0) {
            StartupWarningBanner(
                missingTools: startupCheck.warningItems,
                isDismissed: $startupCheck.isDismissed
            )
            if let warning = store.lastOperationError {
                OperationErrorBanner(message: warning) {
                    store.lastOperationError = nil
                }
            }
        }
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
                .tint(FlotillaColors.accent)
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
