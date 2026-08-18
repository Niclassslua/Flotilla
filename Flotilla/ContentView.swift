import SwiftUI
import SessionKit
import PersistenceKit
import GitKit
import SettingsKit
import DesignSystem
import HooksKit

struct ContentView: View {
    @Environment(\.openSettings) private var openSettings
    @Bindable var navigator: WorkspaceNavigator

    @Bindable var store: AppStore
    let terminalManager: TerminalManager
    var hookCoordinator: HookCoordinator?
    @Bindable var startupCheck: StartupCheckViewModel
    @Bindable var settingsViewModel: SettingsViewModel
    @State private var activityStore: SessionActivityStore

    init(
        store: AppStore,
        terminalManager: TerminalManager,
        navigator: WorkspaceNavigator,
        hookCoordinator: HookCoordinator? = nil,
        startupCheck: StartupCheckViewModel,
        settingsViewModel: SettingsViewModel,
        screenReader: any SessionScreenReading
    ) {
        self.store = store
        self.terminalManager = terminalManager
        self.navigator = navigator
        self.hookCoordinator = hookCoordinator
        self.startupCheck = startupCheck
        self.settingsViewModel = settingsViewModel
        self._activityStore = State(initialValue: SessionActivityStore(screenReader: screenReader))
    }

    private var defaultAgent: AgentKind {
        let agentStrings = AgentKind.allCases.map { $0.rawValue }
        if settingsViewModel.settings.sessionDefaults.defaultAgentRawValue >= 0 && settingsViewModel.settings.sessionDefaults.defaultAgentRawValue < agentStrings.count {
            return AgentKind(rawValue: agentStrings[settingsViewModel.settings.sessionDefaults.defaultAgentRawValue]) ?? AgentKind.claudeCode
        }
        return AgentKind.claudeCode
    }

    var body: some View {
        VStack(spacing: 0) {
            globalBar
            Divider()
            StartupWarningBanner(
                missingTools: startupCheck.warningItems,
                isDismissed: $startupCheck.isDismissed
            )
            if let error = store.lastOperationError {
                OperationErrorBanner(message: error) {
                    store.lastOperationError = nil
                }
            }
            workspace
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(FlotillaColors.canvas)
        .animation(.snappy(duration: 0.22), value: navigator.destination)
        .animation(.snappy(duration: 0.18), value: navigator.sessionLens)
        .animation(.snappy(duration: 0.18), value: navigator.projectLens)
        .sheet(item: $presentedSheet) { sheet in
            sheetContent(sheet)
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            Text(hookCoordinator?.lastNotifiedSessionTitle ?? "none")
                .accessibilityIdentifier("LastNotifiedSession")
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .allowsHitTesting(false)
        }
        #endif
        .task {
            await restoreWorkspaceSelection()
            applyTerminalPreferences()
        }
        .onChange(of: navigator.layout) { previous, mode in
            PerfLog.beginTransition("layout \(previous.rawValue) → \(mode.rawValue)")
            settingsViewModel.settings.workspace.viewMode = mode.rawValue
        }
        .onChange(of: navigator.sessionLens) { _, lens in
            settingsViewModel.settings.workspace.detailPanel = lens.rawValue
        }
        .onChange(of: navigator.projectLens) { _, lens in
            // project lens not stored in settings currently
        }
        .onChange(of: store.selectedSessionID) { _, sessionID in
            settingsViewModel.settings.workspace.selectedSessionID = sessionID?.uuidString
            navigator.selectedSessionID = sessionID
        }
        .onChange(of: navigator.selectedSessionID) { _, sessionID in
            store.selectedSessionID = sessionID
        }
        .onChange(of: store.sessions.count) {
            terminalManager.retainControllers(for: Set(store.sessions.map(\.id)))
            hookCoordinator?.observeAll()
        }
        .onChange(of: store.sessions.map(\.status)) {
            hookCoordinator?.observeAll()
        }
        .onChange(of: settingsViewModel.settings.terminal) {
            applyTerminalPreferences()
        }
        .onChange(of: navigator.destination) { _, _ in
            // destination changes handled by navigator
        }
        .onChange(of: navigator.selectedProjectID) { _, projectID in
            store.selectedProjectID = projectID
        }
    }

    @State private var presentedSheet: WorkspaceSheet?

    private let trafficLightInset: CGFloat = 82
    private let globalBarControlHeight: CGFloat = 28

    private var globalBar: some View {
        HStack(spacing: FlotillaSpacing.xSmall) {
            Button {
                navigator.destination = .overview
            } label: {
                HStack(spacing: 7) {
                    ZStack {
                        RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                            .fill(FlotillaColors.accent)
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 24, height: 24)
                    Text("Flotilla")
                        .font(.system(size: 13, weight: .semibold))
                    Text("BETA")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(FlotillaColors.accent)
                }
            }
            .buttonStyle(.plain)
            .help("Overview")
            .accessibilityIdentifier("Global.Overview")

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 8)

            globalDestinationButton(.overview)
            globalDestinationButton(.sessions)
            globalDestinationButton(.projects)

            GlobalBarButton(
                systemImage: "plus",
                label: nil,
                style: .accent,
                help: "New session",
                identifier: "NewSessionButton",
                height: globalBarControlHeight
            ) {
                presentedSheet = .createSession
            }

            Spacer(minLength: 12)

            if navigator.destination == .sessions {
                Picker("View Mode", selection: $navigator.layout) {
                    ForEach(WorkspaceLayout.allCases) { layout in
                        Label(layout.title, systemImage: layout.systemImage).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .labelsHidden()
                .frame(width: 100)
                .help("Switch session layout")
                .accessibilityIdentifier("ViewModePicker")
            }

            GlobalBarButton(
                systemImage: "arrow.clockwise",
                label: "\(store.sessions.filter { $0.status == .finished || $0.status == .crashed }.count)",
                style: .plain,
                help: "Restore stopped sessions",
                identifier: "Global.Restore stopped sessions",
                height: globalBarControlHeight
            ) {
                presentedSheet = .restore
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(FlotillaColors.statusWorking)
                    .frame(width: 6, height: 6)
                Text("LOCAL")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)

            GlobalBarButton(
                systemImage: "keyboard",
                label: nil,
                style: .plain,
                help: "Keyboard shortcuts",
                height: globalBarControlHeight
            ) {
                presentedSheet = .shortcuts
            }
            GlobalBarButton(
                systemImage: "command",
                label: nil,
                style: .plain,
                help: "Command palette",
                identifier: "CommandPaletteButton",
                height: globalBarControlHeight
            ) {
                presentedSheet = .commandPalette
            }
            GlobalBarButton(
                systemImage: "gearshape",
                label: nil,
                style: .plain,
                help: "Settings",
                height: globalBarControlHeight
            ) {
                openSettings()
            }
        }
        .padding(.leading, trafficLightInset)
        .padding(.trailing, 10)
        .frame(height: 46)
        .background(FlotillaColors.sidebar)
    }

    private func globalDestinationButton(_ item: AppDestination) -> some View {
        GlobalBarButton(
            systemImage: item.systemImage,
            label: item.title,
            style: navigator.destination == item ? .selected : .plain,
            help: item.title,
            identifier: "Global.\(item.title)",
            height: globalBarControlHeight
        ) {
            navigator.destination = item
            if item == .sessions {
                navigator.layout = .focus
            }
        }
    }

    @ViewBuilder
    private var workspace: some View {
        switch navigator.destination {
        case .overview:
            HomeDashboardView(
                store: store,
                openProject: openProject,
                openSession: openSession,
                settingsViewModel: settingsViewModel,
                openCodeSubscription: settingsViewModel.settings.openCodeSubscription,
                defaultAgent: defaultAgent
            )
        case .projects:
            ProjectsWorkspaceView(
                store: store,
                selectedProjectID: $navigator.selectedProjectID,
                openSession: openSession,
                terminalManager: terminalManager,
                openCodeSubscription: settingsViewModel.settings.openCodeSubscription
            )
        case .sessions:
            sessionsWorkspace
        }
    }

    private var sessionsWorkspace: some View {
        NavigationSplitView {
            sessionMinimap
                .navigationSplitViewColumnWidth(min: 215, ideal: 248, max: 320)
        } detail: {
            Group {
                switch navigator.layout {
                case .focus:
                    focusedSessionWorkspace
                case .grid:
                    GridView(
                        store: store,
                        terminalManager: terminalManager,
                        activeSessionID: $activeGridSessionID,
                        openSession: openSession,
                        settingsViewModel: settingsViewModel
                    )
                case .board:
                    KanbanTabView(
                        store: store,
                        terminalManager: terminalManager,
                        openSession: openSession
                    )
                case .list:
                    listView
                }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.28))
        }
        .navigationSplitViewStyle(.balanced)
        .background(FlotillaColors.canvas)
    }

    @State private var activeGridSessionID: UUID?

    private var sessionMinimap: some View {
        List(selection: $store.selectedSessionID) {
            ForEach(store.projects) { project in
                Section {
                    ForEach(store.sessions(for: project)) { session in
                        sessionRow(session)
                    }
                } header: {
                    SessionGroupHeader(
                        title: project.name,
                        count: store.sessions(for: project).count,
                        onCreate: {
                            navigator.selectedProjectID = project.id
                            presentedSheet = .createSession
                        }
                    )
                }
            }

            if !store.generalSessions.isEmpty {
                Section {
                    ForEach(store.generalSessions) { session in
                        sessionRow(session)
                    }
                } header: {
                    SessionGroupHeader(title: "General", count: store.generalSessions.count) {
                        presentedSheet = .createSession
                    }
                }
            }

            if store.projects.isEmpty && store.generalSessions.isEmpty {
                Section("Sessions") {
                    Text("No sessions yet")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(FlotillaColors.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { minimapHeader }
        .navigationTitle("Sessions")
        .accessibilityIdentifier("SidebarList")
        .sheet(item: $sessionPendingDeletion) { session in
            DeleteSessionSheet(
                session: session,
                onCancel: { sessionPendingDeletion = nil },
                onDelete: { deleteWorktree in
                    sessionPendingDeletion = nil
                    Task {
                        await store.deleteSession(
                            sessionID: session.id,
                            deleteWorktree: deleteWorktree,
                            deleteBranch: settingsViewModel.settings.git.deleteBranchWithWorktree
                        )
                    }
                }
            )
        }
    }

    @State private var sessionPendingDeletion: Session?

    private var minimapHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("LIVE SESSIONS")
                        .font(.caption2.weight(.bold))
                        .tracking(0.9)
                        .foregroundStyle(FlotillaColors.accent)
                    Text("\(store.sessions.filter { $0.status == .working }.count) working · \(store.sessions.filter { $0.status == .waitingForInput }.count) need input · \(store.sessions.filter { $0.status == .ready }.count) ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button {
                    presentedSheet = .restore
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Restore stopped sessions")
            }
            SessionActivityStrip(sessions: store.sessions)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(FlotillaColors.sidebar)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var focusedSessionWorkspace: some View {
        if let session = store.selectedSession {
            VStack(spacing: 0) {
                SessionToolbarView(
                    session: session,
                    project: store.project(for: session),
                    gitService: store.gitService,
                    selectedLens: $navigator.sessionLens,
                    isChangesInspectorOpen: $navigator.isChangesInspectorOpen
                )
                .id(session.id)
                sessionSurface(for: session)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .inspector(isPresented: $navigator.isChangesInspectorOpen) {
                DiffPanelView(session: session, gitService: store.gitService)
                    .inspectorColumnWidth(min: 300, ideal: 390, max: 560)
                    .id("inspector-\(session.id)")
            }
        } else {
            EmptyWorkspaceView(
                hasSessions: !store.sessions.isEmpty,
                onCreate: { presentedSheet = .createSession }
            )
            .accessibilityIdentifier("DetailPlaceholder")
        }
    }

    @ViewBuilder
    private var listView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(store.sessions) { session in
                    Button {
                        store.selectedSessionID = session.id
                    } label: {
                        SessionCard(
                            session: session,
                            variant: .row,
                            diffStatStore: store.diffStatStore,
                            activityStore: activityStore,
                            isSelected: navigator.selectedSessionID == session.id,
                            onTap: { store.selectedSessionID = session.id },
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

    @ViewBuilder
    private func sessionSurface(for session: Session) -> some View {
        switch navigator.sessionLens {
        case .terminal:
            terminal(for: session)
        case .files:
            FileBrowserView(rootURL: workspaceRoot(for: session))
                .id(session.id)
        case .instructions:
            RulesPanelView(rootURL: workspaceRoot(for: session), filter: .all)
                .id(session.id)
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
                    outputHandler: { [weak store] data in
                        store?.appendTerminalOutput(data, toSessionID: session.id)
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
    private func sheetContent(_ sheet: WorkspaceSheet) -> some View {
        switch sheet {
        case .createSession:
            CreateSessionView(
                store: store,
                createWorktreeByDefault: settingsViewModel.settings.sessionDefaults.createWorktreeByDefault,
                initialProject: navigator.selectedProjectID.flatMap { id in store.projects.first { $0.id == id } },
                didCreateSession: openSession
            )
        case .commandPalette:
            CommandPaletteView(
                projects: store.projects,
                sessions: store.sessions,
                perform: perform,
                openProject: openProject,
                openSession: openSession,
                onDismiss: { presentedSheet = nil }
            )
        case .shortcuts:
            KeyboardShortcutsView()
        case .restore:
            RestoreSessionsView(sessions: store.sessions) { id in
                store.restartSession(sessionID: id)
            }
        case .deleteSession(let sessionID):
            if let session = store.sessions.first(where: { $0.id == sessionID }) {
                DeleteSessionSheet(
                    session: session,
                    onCancel: { navigator.presentedSheet = nil },
                    onDelete: { deleteWorktree in
                        navigator.presentedSheet = nil
                        Task {
                            await store.deleteSession(
                                sessionID: sessionID,
                                deleteWorktree: deleteWorktree,
                                deleteBranch: settingsViewModel.settings.git.deleteBranchWithWorktree
                            )
                        }
                    }
                )
            }
        }
    }

    private func sessionRow(_ session: Session) -> some View {
        SessionCard(
            session: session,
            variant: .row,
            diffStatStore: store.diffStatStore,
            activityStore: activityStore,
            isSelected: navigator.selectedSessionID == session.id,
            onTap: { store.selectedSessionID = session.id },
            onDelete: { sessionPendingDeletion = session },
            onRestart: { store.restartSession(sessionID: session.id) },
            onRevealInFinder: {
                let path = session.worktree?.worktreePath ?? session.workingDirectory
                NSWorkspace.shared.activateFileViewerSelecting([path])
            },
            onCopyPath: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString((session.worktree?.worktreePath ?? session.workingDirectory).path, forType: .string)
            },
            onCopyBranch: {
                if let branch = session.worktree?.branchName {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(branch, forType: .string)
                }
            },
            terminal: { EmptyView() }
        )
        .tag(session.id)
        .accessibilityIdentifier("SessionRow-\(session.title)")
        .contextMenu {
            Button("Delete Session…", role: .destructive) {
                sessionPendingDeletion = session
            }
            .accessibilityIdentifier("SessionRow-\(session.title)-DeleteMenuItem")
        }
    }

    private func restoreWorkspaceSelection() async {
        if navigator.selectedSessionID == nil,
           let persisted = settingsViewModel.settings.workspace.selectedSessionID.flatMap(UUID.init(uuidString:)),
           store.sessions.contains(where: { $0.id == persisted }) {
            navigator.selectedSessionID = persisted
            store.selectedSessionID = persisted
        }
    }

    private func openSession(_ id: UUID) {
        navigator.destination = .sessions
        navigator.layout = .focus
        navigator.selectedSessionID = id
        store.selectedSessionID = id
    }

    private func openProject(_ id: UUID) {
        navigator.selectedProjectID = id
        navigator.destination = .projects
    }

    private func workspaceRoot(for session: Session) -> URL {
        session.worktree?.worktreePath ?? session.workingDirectory
    }

    private func applyTerminalPreferences() {
        let preferences = settingsViewModel.settings.terminal
        terminalManager.applyPreferences(
            fontSize: preferences.fontSize,
            optionAsMetaKey: preferences.optionActsAsMeta,
            scrollSensitivity: preferences.scrollSpeed,
            gpuRendering: preferences.gpuRendering
        )
    }

    private func perform(_ command: WorkspaceCommand) {
        switch command {
        case .newSession:
            presentedSheet = .createSession
        case .showOverview:
            navigator.destination = .overview
        case .showProjects:
            navigator.destination = .projects
        case .showSessions:
            navigator.destination = .sessions
            navigator.layout = .focus
        case .showGrid:
            navigator.destination = .sessions
            navigator.layout = .grid
        case .showBoard:
            navigator.destination = .sessions
            navigator.layout = .board
        case .showTerminal:
            navigator.destination = .sessions
            navigator.layout = .focus
            navigator.sessionLens = .terminal
        case .showFiles:
            navigator.destination = .sessions
            navigator.layout = .focus
            navigator.sessionLens = .files
        case .showInstructions:
            navigator.destination = .sessions
            navigator.layout = .focus
            navigator.sessionLens = .instructions
        case .showChanges:
            navigator.destination = .sessions
            navigator.layout = .focus
            navigator.isChangesInspectorOpen = true
        case .restoreSessions:
            presentedSheet = .restore
        case .showSettings:
            openSettings()
        }
    }
private struct SessionGroupHeader: View {
    let title: String
    let count: Int
    let onCreate: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer()
            Button(action: onCreate) {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("New session")
        }
    }
}

private struct GlobalBarButton: View {
    enum Style {
        case plain
        case selected
        case accent
    }

    let systemImage: String
    let label: String?
    let style: Style
    let help: String
    var identifier: String?
    let height: CGFloat
    let action: () -> Void

    @State private var isHovering = false

    private var foreground: Color {
        switch style {
        case .plain: isHovering ? .white : Color.white.opacity(0.62)
        case .selected: .white
        case .accent: .white
        }
    }

    private var background: Color {
        switch style {
        case .plain: isHovering ? FlotillaColors.surfaceElevated.opacity(0.6) : .clear
        case .selected: FlotillaColors.surfaceElevated
        case .accent: FlotillaColors.accent
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: style == .accent ? .bold : .regular))
                if let label {
                    Text(label)
                        .font(.system(size: 12, weight: style == .selected ? .semibold : .regular))
                }
            }
            .padding(.horizontal, 9)
            .frame(height: height)
            .frame(minWidth: label == nil ? height : nil)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityIdentifier(identifier ?? "Global.\(help)")
    }
}
}