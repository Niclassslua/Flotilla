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

    /// Files still lands on the project scope. The sidebar toggle opens the
    /// compact, session-scoped Git inspector without unmounting the terminal
    /// beneath it; the full Changes workspace is reached from the View menu
    /// (⇧⌘G) rather than from a button on the bar.
    private func sessionBarActions(for session: Session) -> SessionBarActions {
        SessionBarActions(
            onRename: { store.renameSession(sessionID: session.id, newTitle: $0) },
            onToggleGitSidebar: {
                gitSidebarSessionID = gitSidebarSessionID == session.id ? nil : session.id
            },
            onBrowseFiles: { navigator.openProjectPanel(.files, scopedTo: session) },
            handoffTargets: store.handoffTargets(for: session),
            onHandoff: { target in Task { await store.handoffSession(sessionID: session.id, to: target) } }
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

/// The detail column with nothing to show: either a first run with no sessions
/// at all, or a fleet where none is selected. The first-run branch doubles as
/// onboarding — it names the three moves the app is built around and shows the
/// status signals the user will be reading from then on.
struct EmptyWorkspaceView: View {
    let hasSessions: Bool
    let onCreate: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        Group {
            if hasSessions {
                selectPrompt
            } else {
                onboarding
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .top) {
            RadialGradient(
                colors: [FlotillaColors.accent.opacity(0.07), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 460
            )
            .frame(height: 620)
            .allowsHitTesting(false)
        }
        .background(FlotillaColors.canvas)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
        .onAppear {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.5)) { appeared = true }
        }
    }

    // MARK: First run

    private var onboarding: some View {
        VStack(spacing: FlotillaSpacing.xLarge) {
            FormationMark(reduceMotion: reduceMotion)

            VStack(spacing: FlotillaSpacing.small) {
                Text("Your agents, in formation")
                    .font(FlotillaTypography.display)
                    .foregroundStyle(FlotillaColors.textPrimary)
                Text("Run coding agents in parallel, each in its own worktree — and keep sight of every one.")
                    .font(FlotillaTypography.body)
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            workflowPanel

            VStack(spacing: FlotillaSpacing.medium) {
                Button("Launch First Session", action: onCreate)
                    .buttonStyle(.borderedProminent)
                    .tint(FlotillaColors.accent)
                    .controlSize(.large)
                ShortcutHintRow(hints: [("⌘N", "new session"), ("⌘K", "command palette")])
            }
        }
        .padding(FlotillaSpacing.xxLarge)
        .frame(maxWidth: 560)
    }

    private var workflowPanel: some View {
        VStack(spacing: 0) {
            WorkflowRow(
                icon: "terminal",
                title: "Launch an isolated session",
                detail: "Each agent works in its own git worktree, so parallel runs never step on each other."
            )
            Divider().overlay(FlotillaColors.separator)
            WorkflowRow(icon: "dot.radiowaves.up.forward", title: "Read the signals") {
                SignalLegend()
            }
            Divider().overlay(FlotillaColors.separator)
            WorkflowRow(
                icon: "arrow.left.arrow.right",
                title: "Move without losing context",
                detail: "Hand a session to another agent or jump between worktrees — history and state follow."
            )
        }
        .flotillaPanel()
    }

    // MARK: Fleet with no selection

    private var selectPrompt: some View {
        VStack(spacing: FlotillaSpacing.large) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 34, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(FlotillaColors.accent)
                .accessibilityHidden(true)
            VStack(spacing: FlotillaSpacing.small) {
                Text("Choose a session")
                    .font(FlotillaTypography.title)
                    .foregroundStyle(FlotillaColors.textPrimary)
                Text("Select an agent from the sidebar to open its live terminal and workspace.")
                    .font(FlotillaTypography.body)
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            VStack(spacing: FlotillaSpacing.medium) {
                Button("New Session", action: onCreate)
                    .buttonStyle(.borderedProminent)
                    .tint(FlotillaColors.accent)
                    .controlSize(.large)
                ShortcutHintRow(hints: [("⌘[", "previous"), ("⌘]", "next"), ("⌘K", "palette")])
            }
        }
        .padding(FlotillaSpacing.xxLarge)
    }
}

/// The app's mark in a soft accent medallion with a slow sonar ring — enough
/// life to read as "live fleet" without becoming a distraction.
private struct FormationMark: View {
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(FlotillaColors.accent.opacity(0.10))
                .frame(width: 96, height: 96)
            Circle()
                .strokeBorder(FlotillaColors.accent.opacity(0.4), lineWidth: 1)
                .frame(width: 96, height: 96)
                .scaleEffect(pulse ? 1.3 : 1)
                .opacity(pulse ? 0 : 0.6)
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 40, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(FlotillaColors.accent)
        }
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 2.4).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

private struct WorkflowRow<Accessory: View>: View {
    let icon: String
    let title: String
    var detail: String?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: FlotillaSpacing.medium) {
            Image(systemName: icon)
                .font(.system(size: FlotillaIconSize.medium, weight: .medium))
                .foregroundStyle(FlotillaColors.accent)
                .frame(width: 34, height: 34)
                .background(
                    FlotillaColors.accent.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                )
            VStack(alignment: .leading, spacing: FlotillaSpacing.xSmall) {
                Text(title)
                    .font(FlotillaTypography.callout.weight(.semibold))
                    .foregroundStyle(FlotillaColors.textPrimary)
                if let detail {
                    Text(detail)
                        .font(FlotillaTypography.caption)
                        .foregroundStyle(FlotillaColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                accessory()
            }
            Spacer(minLength: 0)
        }
        .padding(FlotillaSpacing.large)
    }
}

extension WorkflowRow where Accessory == EmptyView {
    init(icon: String, title: String, detail: String?) {
        self.init(icon: icon, title: title, detail: detail, accessory: { EmptyView() })
    }
}

/// The three fleet signals, spelled out with their real status colours so the
/// legend the user sees here matches the dots on every session row.
private struct SignalLegend: View {
    private let signals: [(color: Color, label: String)] = [
        (FlotillaColors.statusWorking, "Working"),
        (FlotillaColors.statusWaitingForInput, "Needs input"),
        (FlotillaColors.statusReady, "Ready for review"),
    ]

    var body: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            ForEach(signals, id: \.label) { signal in
                HStack(spacing: 5) {
                    Circle()
                        .fill(signal.color)
                        .frame(width: 7, height: 7)
                    Text(signal.label)
                        .font(FlotillaTypography.caption2)
                        .foregroundStyle(FlotillaColors.textSecondary)
                }
            }
        }
        .padding(.top, 2)
    }
}

private struct ShortcutHintRow: View {
    let hints: [(key: String, label: String)]

    var body: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            ForEach(hints, id: \.key) { hint in
                HStack(spacing: 6) {
                    Text(hint.key)
                        .font(FlotillaTypography.caption2.monospaced())
                        .foregroundStyle(FlotillaColors.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            FlotillaColors.surfaceElevated,
                            in: RoundedRectangle(cornerRadius: FlotillaRadius.control)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: FlotillaRadius.control)
                                .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
                        )
                    Text(hint.label)
                        .font(FlotillaTypography.caption2)
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
            }
        }
        .accessibilityHidden(true)
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
