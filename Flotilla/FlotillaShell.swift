import SwiftUI
import SessionKit
import PersistenceKit
import GitKit
import SettingsKit
import DesignSystem
import HooksKit

struct FlotillaShell: View {
    @Environment(\.openSettings) private var openSettings
    @Bindable var navigator: WorkspaceNavigator
    @Bindable var store: AppStore
    let terminalManager: TerminalManager
    var hookCoordinator: HookCoordinator?
    @Bindable var startupCheck: StartupCheckViewModel
    @Bindable var settingsViewModel: SettingsViewModel
    @State private var activityStore: SessionActivityStore
    @State private var workspaceRegistry: SessionWorkspaceRegistry
    @State private var commandPaletteController: CommandPaletteWindowController?

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
        self._workspaceRegistry = State(initialValue: SessionWorkspaceRegistry(store: store, gitService: store.gitService))
    }

    var body: some View {
        splitView
            .sheet(item: sheetBinding) { sheet in
                sheetContent(sheet)
            }
            .task {
                await restoreWorkspaceSelection()
                syncSidebarColumn(for: facet)
                applyTerminalPreferences()
            }
            .onChange(of: navigator.presentedSheet) { _, sheet in
                if case .commandPalette = sheet {
                    presentCommandPalette()
                    navigator.presentedSheet = nil
                }
            }
            .modifier(ShellLifecycleModifier(
                navigator: navigator,
                store: store,
                terminalManager: terminalManager,
                hookCoordinator: hookCoordinator,
                settingsViewModel: settingsViewModel,
                applyTerminalPreferences: applyTerminalPreferences
            ))
    }

    private var facet: SidebarFacet { SidebarFacet(navigator.selection) }

    /// The rail is a sibling of the split view, not its first column — a
    /// fixed-width column is something `NavigationSplitView` does not keep
    /// (see `SidebarRail`). The split view then owns only the session list,
    /// which it may collapse without taking the navigation away with it.
    private var splitView: some View {
        HStack(spacing: 0) {
            SidebarRail(
                facet: facet,
                showLabels: settingsViewModel.settings.workspace.sidebarRailLabels,
                onSelect: { navigator.selection = $0.rootItem },
                onCreateSession: { navigator.presentedSheet = .createSession }
            )
            Divider()
            NavigationSplitView(columnVisibility: $navigator.columnVisibility) {
                FleetSessionList(
                    store: store,
                    selection: $navigator.selection,
                    searchText: navigator.searchText,
                    onOpenSession: { id in
                        navigator.selection = .session(id)
                        store.selectedSessionID = id
                    },
                    onRequestDelete: { navigator.presentedSheet = .deleteSession($0) }
                )
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
                .searchable(text: $navigator.searchText, placement: .sidebar, prompt: "Projects and sessions")
            } detail: {
                DetailColumn(
                    store: store,
                    navigator: navigator,
                    settingsViewModel: settingsViewModel,
                    terminalManager: terminalManager,
                    workspaceRegistry: workspaceRegistry,
                    activityStore: activityStore,
                    onOpenSession: { id in
                        navigator.selection = .session(id)
                        store.selectedSessionID = id
                    },
                    onOpenProject: { id in
                        navigator.selection = .project(id)
                        store.selectedProjectID = id
                    },
                    onCreateSession: { navigator.presentedSheet = .createSession }
                )
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
        .onChange(of: facet) { _, newFacet in syncSidebarColumn(for: newFacet) }
        .animation(.snappy(duration: 0.22), value: navigator.selection)
        .animation(.snappy(duration: 0.18), value: navigator.presentation)
        .animation(.snappy(duration: 0.18), value: navigator.inspectorTab)
    }

    /// Only Sessions has a list to put in the sidebar column; the other
    /// facets collapse it so the detail column starts right at the rail
    /// instead of behind an empty strip.
    private func syncSidebarColumn(for facet: SidebarFacet) {
        navigator.columnVisibility = facet == .sessions ? .all : .detailOnly
    }

    /// Excludes `.commandPalette`, which is presented as a floating panel
    /// (see `presentCommandPalette`), not a modal sheet — a sheet can't
    /// dismiss itself when the user clicks outside it, but a panel can.
    private var sheetBinding: Binding<WorkspaceSheet?> {
        Binding(
            get: {
                if case .commandPalette = navigator.presentedSheet { return nil }
                return navigator.presentedSheet
            },
            set: { navigator.presentedSheet = $0 }
        )
    }

    private func presentCommandPalette() {
        let controller = commandPaletteController ?? {
            let controller = CommandPaletteWindowController { [weak navigator] in
                navigator?.presentedSheet = nil
            }
            commandPaletteController = controller
            return controller
        }()
        controller.setContent(
            CommandPaletteView(
                projects: store.projects,
                sessions: store.sessions,
                perform: perform,
                openProject: openProject,
                openSession: openSession,
                onDismiss: { [weak controller] in controller?.close() }
            )
        )
        controller.show(relativeTo: NSApp.keyWindow ?? NSApp.mainWindow)
    }

    @ViewBuilder
    private func sheetContent(_ sheet: WorkspaceSheet) -> some View {
        switch sheet {
        case .createSession:
            CreateSessionView(
                store: store,
                createWorktreeByDefault: settingsViewModel.settings.sessionDefaults.createWorktreeByDefault,
                initialProject: navigator.selectedProjectID.flatMap { id in store.projects.first { $0.id == id } },
                didCreateSession: { id in
                    navigator.selection = .session(id)
                    store.selectedSessionID = id
                }
            )
        case .commandPalette:
            EmptyView()
        case .shortcuts:
            KeyboardShortcutsView()
        case .restore:
            RestoreSessionsView(sessions: store.sessions) { id in
                store.restartSession(sessionID: id)
            }
        case .deleteSession(let sessionID):
            // Not force-unwrapped: the session can disappear between the sheet
            // being requested and presented (deleted from another entry point,
            // or the store reloading), and a missing one must dismiss rather
            // than crash.
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
            } else {
                Color.clear.onAppear { navigator.presentedSheet = nil }
            }
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
        navigator.selection = .session(id)
        store.selectedSessionID = id
    }

    private func openProject(_ id: UUID) {
        navigator.selectedProjectID = id
        navigator.selection = .project(id)
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
            navigator.presentedSheet = .createSession
        case .showOverview:
            navigator.selection = .overview
        case .showProjects:
            navigator.selection = .allProjects
        case .showSessions:
            navigator.selection = .allSessions
            navigator.presentation = .focus
        case .showGrid:
            navigator.selection = .allSessions
            navigator.presentation = .grid
        case .showBoard:
            navigator.selection = .allSessions
            navigator.presentation = .board
        case .showTerminal:
            navigator.selection = .allSessions
            navigator.presentation = .focus
            navigator.sessionLens = .terminal
        case .showFiles:
            navigator.selection = .allSessions
            navigator.presentation = .focus
            navigator.sessionLens = .files
        case .showInstructions:
            navigator.selection = .allSessions
            navigator.presentation = .focus
            navigator.sessionLens = .instructions
        case .showChanges:
            navigator.selection = .allSessions
            navigator.presentation = .focus
            navigator.isChangesInspectorOpen = true
        case .restoreSessions:
            navigator.presentedSheet = .restore
        case .showSettings:
            openSettings()
        }
    }
}

/// Splits the tail of onChange handlers out of `FlotillaShell.body` — folding
/// them all into one modifier chain made the type checker time out.
private struct ShellLifecycleModifier: ViewModifier {
    @Bindable var navigator: WorkspaceNavigator
    @Bindable var store: AppStore
    let terminalManager: TerminalManager
    var hookCoordinator: HookCoordinator?
    @Bindable var settingsViewModel: SettingsViewModel
    let applyTerminalPreferences: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: navigator.presentation) { _, mode in
                settingsViewModel.settings.workspace.viewMode = mode.rawValue
            }
            .onChange(of: navigator.inspectorTab) { _, tab in
                settingsViewModel.settings.workspace.detailPanel = tab.rawValue
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
    }
}
