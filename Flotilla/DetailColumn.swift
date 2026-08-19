import SwiftUI
import SessionKit
import DesignSystem
import TerminalKit
import GitKit

struct DetailColumn: View {
    @Environment(\.openSettings) private var openSettings
    @Bindable var store: AppStore
    @Bindable var navigator: WorkspaceNavigator
    @Bindable var settingsViewModel: SettingsViewModel
    @Bindable var startupCheck: StartupCheckViewModel
    let terminalManager: TerminalManager
    let workspaceRegistry: SessionWorkspaceRegistry
    let activityStore: SessionActivityStore
    let onOpenSession: (UUID) -> Void
    let onOpenProject: (UUID) -> Void
    let onCreateSession: () -> Void
    let onCommandPalette: () -> Void
    let onInspectorToggle: () -> Void

    @State private var activeGridSessionID: UUID?

    var body: some View {
        let _ = navigator.presentedSheet
        Group {
            switch navigator.selection {
            case .overview:
                overviewContent
            case .allSessions:
                sessionsContent(showingAll: true)
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
                onCommandPalette: onCommandPalette,
                onInspectorToggle: onInspectorToggle
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
            terminalManager: terminalManager,
            openCodeSubscription: settingsViewModel.settings.openCodeSubscription,
            highlightUnseenCommits: settingsViewModel.settings.git.highlightUnseenCommits,
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
        if session.status != .crashed && session.status != .finished,
           let process = store.process(for: session.id) {
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
                onBackToOverview: { navigator.selection = .overview }
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

    private func workspaceRoot(for session: Session) -> URL {
        session.worktree?.worktreePath ?? session.workingDirectory
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
