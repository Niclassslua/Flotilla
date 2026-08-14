import SwiftUI
import SessionKit
import PersistenceKit
import GitKit
import SettingsKit
import DesignSystem

struct ContentView: View {
    @Environment(\.openSettings) private var openSettings

    @Bindable var store: AppStore
    let terminalManager: TerminalManager
    var hookCoordinator: HookCoordinator?
    @Bindable var startupCheck: StartupCheckViewModel
    @Bindable var settingsViewModel: SettingsViewModel

    @State private var destination: AppDestination = .sessions
    @State private var presentedSheet: WorkspaceSheet?
    @State private var viewMode: WorkspaceViewMode
    @State private var activeGridSessionID: UUID?
    @State private var selectedSurface: SessionSurface
    @State private var selectedProjectID: UUID?
    @State private var sessionPendingDeletion: Session?
    @State private var isGitInspectorPresented = false

    init(
        store: AppStore,
        terminalManager: TerminalManager,
        hookCoordinator: HookCoordinator? = nil,
        startupCheck: StartupCheckViewModel,
        settingsViewModel: SettingsViewModel
    ) {
        self.store = store
        self.terminalManager = terminalManager
        self.hookCoordinator = hookCoordinator
        self.startupCheck = startupCheck
        self.settingsViewModel = settingsViewModel
        _viewMode = State(
            initialValue: WorkspaceViewMode(rawValue: settingsViewModel.settings.workspace.viewMode) ?? .single
        )
        let storedPanel = settingsViewModel.settings.workspace.detailPanel
        _selectedSurface = State(
            initialValue: storedPanel == "diff"
                ? .git
                : SessionSurface(rawValue: storedPanel) ?? .terminal
        )
    }

    private var defaultAgent: AgentKind {
        AgentKind(rawValue: settingsViewModel.settings.sessionDefaults.defaultAgentRawValue) ?? .claudeCode
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
        .background(FlotillaPalette.canvas)
        .environment(\.colorScheme, .dark)
        .animation(.snappy(duration: 0.22), value: destination)
        .animation(.snappy(duration: 0.18), value: selectedSurface)
        .sheet(item: $presentedSheet) { sheet in
            sheetContent(sheet)
        }
        .overlay(alignment: .topLeading) {
            Text(hookCoordinator?.lastNotifiedSessionTitle ?? "none")
                .accessibilityIdentifier("LastNotifiedSession")
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .allowsHitTesting(false)
        }
        .task {
            await restoreWorkspaceSelection()
            applyTerminalPreferences()
        }
        .onChange(of: viewMode) { _, mode in
            settingsViewModel.settings.workspace.viewMode = mode.rawValue
        }
        .onChange(of: selectedSurface) { _, panel in
            settingsViewModel.settings.workspace.detailPanel = panel.rawValue
        }
        .onChange(of: store.selectedSessionID) { _, sessionID in
            settingsViewModel.settings.workspace.selectedSessionID = sessionID?.uuidString
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
        .onReceive(NotificationCenter.default.publisher(for: .flotillaNewSession)) { _ in
            presentedSheet = .createSession
        }
        .onReceive(NotificationCenter.default.publisher(for: .flotillaCommandPalette)) { _ in
            presentedSheet = .commandPalette
        }
        .onReceive(NotificationCenter.default.publisher(for: .flotillaShowProjects)) { _ in
            destination = .projects
        }
        .onReceive(NotificationCenter.default.publisher(for: .flotillaShowSessions)) { _ in
            destination = .sessions
            viewMode = .single
        }
        .onReceive(NotificationCenter.default.publisher(for: .flotillaShowGrid)) { _ in
            destination = .sessions
            viewMode = .grid
        }
    }

    private var globalBar: some View {
        HStack(spacing: 4) {
            Button {
                destination = .home
            } label: {
                HStack(spacing: 7) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(FlotillaPalette.ocean)
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
                        .foregroundStyle(FlotillaPalette.ocean)
                }
            }
            .buttonStyle(.plain)
            .help("Home")
            .accessibilityIdentifier("Global.Home")

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 8)

            globalDestinationButton(.projects)
            globalDestinationButton(.sessions)

            Button {
                presentedSheet = .createSession
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 27, height: 24)
                    .background(FlotillaPalette.ocean, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("New session")
            .accessibilityIdentifier("NewSessionButton")

            Spacer(minLength: 12)

            if destination == .sessions {
                Picker("View Mode", selection: $viewMode) {
                    Label("Single", systemImage: "rectangle.inset.filled").tag(WorkspaceViewMode.single)
                    Label("Grid", systemImage: "square.grid.2x2").tag(WorkspaceViewMode.grid)
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .labelsHidden()
                .frame(width: 68)
                .help("Switch session layout")
                .accessibilityIdentifier("ViewModePicker")
            }

            Button {
                presentedSheet = .restore
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                    Text("\(store.sessions.filter { $0.status == .finished || $0.status == .crashed }.count)")
                        .font(.caption2.monospacedDigit())
                }
                .frame(height: 24)
            }
            .buttonStyle(.plain)
            .help("Restore stopped sessions")

            HStack(spacing: 5) {
                Circle()
                    .fill(FlotillaPalette.signal)
                    .frame(width: 6, height: 6)
                Text("LOCAL")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)

            globalIconButton("keyboard", help: "Keyboard shortcuts") {
                presentedSheet = .shortcuts
            }
            globalIconButton("command", help: "Command palette", identifier: "CommandPaletteButton") {
                presentedSheet = .commandPalette
            }
            globalIconButton("gearshape", help: "Settings") {
                openSettings()
            }
        }
        .padding(.leading, 82)
        .padding(.trailing, 10)
        .frame(height: 46)
        .background(FlotillaPalette.sidebar)
    }

    private func globalDestinationButton(_ item: AppDestination) -> some View {
        Button {
            destination = item
        } label: {
            Label(item.title, systemImage: item.systemImage)
                .font(.system(size: 12, weight: destination == item ? .semibold : .regular))
                .padding(.horizontal, 9)
                .frame(height: 28)
                .foregroundStyle(destination == item ? Color.white : Color.white.opacity(0.62))
                .background(
                    destination == item ? FlotillaPalette.elevated : .clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .help(item.title)
        .accessibilityIdentifier("Global.\(item.title)")
    }

    private func globalIconButton(
        _ systemImage: String,
        help: String,
        identifier: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 25, height: 25)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityIdentifier(identifier ?? "Global.\(help)")
    }

    @ViewBuilder
    private var workspace: some View {
        switch destination {
        case .home:
            HomeDashboardView(
                store: store,
                defaultAgent: defaultAgent,
                openProject: openProject,
                openSession: openSession
            )
        case .projects:
            ProjectsWorkspaceView(
                store: store,
                selectedProjectID: $selectedProjectID,
                defaultAgent: defaultAgent,
                openSession: openSession
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
                switch viewMode {
                case .single:
                    focusedSessionWorkspace
                case .grid:
                    GridView(
                        store: store,
                        terminalManager: terminalManager,
                        activeSessionID: $activeGridSessionID,
                        minimumTileWidth: $settingsViewModel.settings.workspace.gridMinimumTileWidth,
                        openSession: openSession
                    )
                }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.28))
        }
        .navigationSplitViewStyle(.balanced)
        .background(FlotillaPalette.canvas)
    }

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
                            selectedProjectID = project.id
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
        .background(FlotillaPalette.sidebar)
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

    private var minimapHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("LIVE SESSIONS")
                        .font(.caption2.weight(.bold))
                        .tracking(0.9)
                        .foregroundStyle(FlotillaPalette.ocean)
                    Text("\(store.sessions.filter { $0.status == .working }.count) working · \(store.sessions.filter { $0.status == .waitingForInput }.count) need input")
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
        .background(FlotillaPalette.sidebar)
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
                    selectedSurface: $selectedSurface,
                    isGitInspectorPresented: $isGitInspectorPresented
                )
                .id(session.id)
                sessionSurface(for: session)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .inspector(isPresented: $isGitInspectorPresented) {
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
    private func sessionSurface(for session: Session) -> some View {
        switch selectedSurface {
        case .terminal:
            terminal(for: session)
        case .git:
            DiffPanelView(session: session, gitService: store.gitService)
                .id(session.id)
        case .files:
            FileBrowserView(rootURL: workspaceRoot(for: session))
                .id(session.id)
        case .rules:
            RulesPanelView(rootURL: workspaceRoot(for: session), filter: .rules)
                .id(session.id)
        case .skills:
            RulesPanelView(rootURL: workspaceRoot(for: session), filter: .skills)
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
                    outputHandler: { [weak store] data in
                        store?.appendTerminalOutput(data, toSessionID: session.id)
                    },
                    inputHandler: { [weak store] in
                        store?.applyObservedStatus(.working, toSessionID: session.id)
                    }
                ),
                presentation: .session,
                isFocused: true
            )
            .id(session.id)
            .background(FlotillaPalette.terminal)
        } else {
            ContentUnavailableView {
                Label(
                    session.status == .crashed ? "Agent Stopped" : "Session Not Running",
                    systemImage: session.status == .crashed ? "exclamationmark.terminal" : "terminal"
                )
            } description: {
                Text("Check the agent executable in Settings, then restart this interactive session.")
            } actions: {
                Button("Restart Session") {
                    store.restartSession(sessionID: session.id)
                }
                .buttonStyle(.borderedProminent)
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
                defaultAgent: defaultAgent,
                createWorktreeByDefault: settingsViewModel.settings.sessionDefaults.createWorktreeByDefault,
                initialProject: selectedProjectID.flatMap { id in store.projects.first { $0.id == id } },
                didCreateSession: openSession
            )
        case .commandPalette:
            CommandPaletteView(
                projects: store.projects,
                sessions: store.sessions,
                perform: perform,
                openProject: openProject,
                openSession: openSession
            )
        case .shortcuts:
            KeyboardShortcutsView()
        case .restore:
            RestoreSessionsView(sessions: store.sessions) { id in
                store.restartSession(sessionID: id)
            }
        }
    }

    private func sessionRow(_ session: Session) -> some View {
        SessionRow(session: session)
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
        if store.selectedSessionID == nil,
           let persisted = settingsViewModel.settings.workspace.selectedSessionID.flatMap(UUID.init(uuidString:)),
           store.sessions.contains(where: { $0.id == persisted }) {
            store.selectedSessionID = persisted
        }
    }

    private func openSession(_ id: UUID) {
        destination = .sessions
        viewMode = .single
        store.selectedSessionID = id
    }

    private func openProject(_ id: UUID) {
        selectedProjectID = id
        destination = .projects
    }

    private func workspaceRoot(for session: Session) -> URL {
        session.worktree?.worktreePath ?? session.workingDirectory
    }

    private func applyTerminalPreferences() {
        let preferences = settingsViewModel.settings.terminal
        terminalManager.applyPreferences(
            fontSize: preferences.fontSize,
            optionAsMetaKey: preferences.optionActsAsMeta,
            scrollSensitivity: preferences.scrollSpeed
        )
    }

    private func perform(_ command: WorkspaceCommand) {
        switch command {
        case .newSession:
            presentedSheet = .createSession
        case .showHome:
            destination = .home
        case .showProjects:
            destination = .projects
        case .showSessions:
            destination = .sessions
            viewMode = .single
        case .showGrid:
            destination = .sessions
            viewMode = .grid
        case .showTerminal:
            destination = .sessions
            viewMode = .single
            selectedSurface = .terminal
        case .showGit:
            destination = .sessions
            viewMode = .single
            selectedSurface = .git
        case .showFiles:
            destination = .sessions
            viewMode = .single
            selectedSurface = .files
        case .showRules:
            destination = .sessions
            viewMode = .single
            selectedSurface = .rules
        case .showSkills:
            destination = .sessions
            viewMode = .single
            selectedSurface = .skills
        case .restoreSessions:
            presentedSheet = .restore
        case .showSettings:
            openSettings()
        }
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

private struct SessionActivityStrip: View {
    let sessions: [Session]

    var body: some View {
        GeometryReader { proxy in
            let shown = Array(sessions.prefix(12))
            let count = max(shown.count, 1)
            HStack(spacing: 3) {
                if shown.isEmpty {
                    Capsule()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 3)
                } else {
                    ForEach(shown) { session in
                        Capsule()
                            .fill(StatusPresentation.color(for: session.status))
                            .frame(width: max(4, (proxy.size.width - CGFloat(count - 1) * 3) / CGFloat(count)), height: 3)
                    }
                }
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

private struct DeleteSessionSheet: View {
    let session: Session
    let onCancel: () -> Void
    let onDelete: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.red)
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Delete “\(session.title)”? ")
                        .font(.title3.weight(.semibold))
                    Text(explanation)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let worktree = session.worktree {
                VStack(alignment: .leading, spacing: 4) {
                    Label(worktree.branchName, systemImage: "arrow.triangle.branch")
                    Text(worktree.worktreePath.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("DeleteSessionDialog.Cancel")
                Spacer()
                if session.worktree != nil {
                    Button("Keep Worktree, Delete Session") { onDelete(false) }
                        .accessibilityIdentifier("DeleteSessionDialog.DeleteSessionOnly")
                }
                Button(session.worktree == nil ? "Delete Session" : "Delete Session & Worktree", role: .destructive) {
                    onDelete(session.worktree != nil)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(
                    session.worktree == nil
                        ? "DeleteSessionDialog.DeleteSessionOnly"
                        : "DeleteSessionDialog.DeleteWithWorktree"
                )
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private var explanation: String {
        session.worktree == nil
            ? "Terminal history and session metadata will be permanently removed."
            : "Remove only Flotilla’s session record, or also clean up its isolated worktree and branch from Git."
    }
}

private struct OperationErrorBanner: View {
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

private struct EmptyWorkspaceView: View {
    let hasSessions: Bool
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 48, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(FlotillaPalette.ocean)
                .accessibilityHidden(true)
            VStack(spacing: 7) {
                Text(hasSessions ? "Choose a session" : "Your agents, in formation")
                    .font(.title2.weight(.semibold))
                Text(hasSessions
                    ? "Select an agent from the minimap to open its live terminal and workspace."
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
        .background(FlotillaPalette.ocean.opacity(0.025))
    }
}

#Preview {
    let repository = try! GRDBSessionRepository()
    ContentView(
        store: AppStore(
            repository: repository,
            gitService: GitService(),
            processManager: SessionProcessManager(),
            worktreeBaseDirectoryProvider: { FileManager.default.temporaryDirectory }
        ),
        terminalManager: TerminalManager(),
        startupCheck: StartupCheckViewModel(),
        settingsViewModel: SettingsViewModel(store: UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: "FlotillaPreview") ?? .standard,
            defaultWorktreeBaseDirectory: FileManager.default.temporaryDirectory.path
        ))
    )
}
