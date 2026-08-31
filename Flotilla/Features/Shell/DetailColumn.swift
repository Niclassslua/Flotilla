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

    /// Files and Changes still land on the project workspace scoped to this
    /// session's own worktree — the same jump the window toolbar used to
    /// offer, moved to the bar that names the session it acts on. The Git
    /// sidebar has nothing to toggle yet and renders disabled.
    private func sessionBarActions(for session: Session) -> SessionBarActions {
        SessionBarActions(
            onRename: { store.renameSession(sessionID: session.id, newTitle: $0) },
            onBrowseFiles: { navigator.openProjectPanel(.files, scopedTo: session) },
            onReviewChanges: { navigator.openProjectPanel(.git, scopedTo: session) }
        )
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
