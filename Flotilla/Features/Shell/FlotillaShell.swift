import SwiftUI
import AppKit
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

    var body: some View {
        let _ = navigator.presentedSheet
        // A plain `.overlay {}` on a `NavigationSplitView`-backed view (like
        // `splitView`) doesn't reliably composite as the true top AppKit
        // layer for hit-testing — clicks can fall straight through to the
        // split view's panes even though the overlay renders visually on
        // top. An explicit `ZStack` avoids that: it's SwiftUI's own stacking
        // container, so every child gets genuine, predictable z-order.
        ZStack {
            splitView
                .sheet(item: modalSheetBinding) { sheet in
                    sheetContent(sheet)
                }
            overlayPresentation
        }
            .task {
                await restoreWorkspaceSelection()
                syncSidebarColumn(for: facet)
                applyTerminalPreferences()
            }
            .modifier(ShellLifecycleModifier(
                navigator: navigator,
                store: store,
                terminalManager: terminalManager,
                hookCoordinator: hookCoordinator,
                settingsViewModel: settingsViewModel,
                applyTerminalPreferences: applyTerminalPreferences
            ))
            #if DEBUG
            .overlay(alignment: .topLeading) {
                Text(hookCoordinator?.lastNotifiedSessionTitle ?? "none")
                    .accessibilityIdentifier("LastNotifiedSession")
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .allowsHitTesting(false)
            }
            #endif
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
                onSelect: { selectedFacet in
                    switch selectedFacet {
                    case .overview:
                        navigator.restoreOverviewSelection()
                    case .sessions:
                        navigator.selection = .allSessions
                    }
                },
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
                    startupCheck: startupCheck,
                    terminalManager: terminalManager,
                    activityStore: activityStore,
                    onOpenSession: { id in
                        navigator.selection = .session(id)
                        store.selectedSessionID = id
                    },
                    onOpenProject: { id in
                        navigator.selection = .project(id)
                        store.selectedProjectID = id
                    },
                    onCreateSession: { navigator.presentedSheet = .createSession },
                    onCommandPalette: { navigator.presentedSheet = .commandPalette }
                )
            }
        }
        .environment(\.workspaceNavigator, navigator)
        .frame(minWidth: 1000, minHeight: 640)
        .onChange(of: facet) { _, newFacet in syncSidebarColumn(for: newFacet) }
        .animation(.snappy(duration: 0.22), value: navigator.selection)
        .animation(.snappy(duration: 0.18), value: navigator.presentation)
    }

    /// Only Sessions has a list to put in the sidebar column; the other
    /// facets collapse it so the detail column starts right at the rail
    /// instead of behind an empty strip.
    private func syncSidebarColumn(for facet: SidebarFacet) {
        navigator.columnVisibility = facet == .sessions ? .all : .detailOnly
    }

    // MARK: - Overlay presentations (New Session, command palette)

    /// A real AppKit sheet is modal to the *window*: clicking anywhere outside
    /// its bounds is inert by design, not a bug — that's correct for a
    /// destructive confirmation like delete, but wrong for a Spotlight-style
    /// launcher that should feel dismissible. `createSession` and
    /// `commandPalette` render as an in-window overlay instead, with a scrim
    /// that dismisses on click and reliable Escape handling, since both live
    /// in the same responder chain as the rest of the window rather than a
    /// separate sheet window.
    private func isOverlayStyleSheet(_ sheet: WorkspaceSheet) -> Bool {
        switch sheet {
        case .createSession, .commandPalette: true
        case .shortcuts, .restore, .deleteSession: false
        }
    }

    /// `.sheet(item:)` filtered to the true-modal cases, so those still get
    /// native AppKit sheet behavior (delete confirmation, shortcuts, restore).
    /// The setter only clears `presentedSheet` when it currently holds one of
    /// those cases — otherwise a `.sheet` dismissal firing while an overlay
    /// case is already presented (e.g. during the cross-fade between the two)
    /// would clobber it.
    private var modalSheetBinding: Binding<WorkspaceSheet?> {
        Binding(
            get: {
                guard let sheet = navigator.presentedSheet, !isOverlayStyleSheet(sheet) else { return nil }
                return sheet
            },
            set: { newValue in
                if let newValue {
                    navigator.presentedSheet = newValue
                } else if let current = navigator.presentedSheet, !isOverlayStyleSheet(current) {
                    navigator.presentedSheet = nil
                }
            }
        )
    }

    @ViewBuilder
    private var overlayPresentation: some View {
        if let sheet = navigator.presentedSheet, isOverlayStyleSheet(sheet) {
            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { navigator.presentedSheet = nil }
                    .transition(.opacity)

                sheetContent(sheet)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Absorb clicks inside the sheet content so they don't fall through to the backdrop
                    }
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
            .zIndex(1)
            .onExitCommand { navigator.presentedSheet = nil }
            // Belt and suspenders: `.onExitCommand`/`.keyboardShortcut(.cancelAction)`
            // only fire if nothing focused inside the overlay consumes Escape
            // first — and a focused NSTextField/NSTextView's own `cancelOperation:`
            // handling can do exactly that before either ever sees the key. A
            // local event monitor intercepts Escape at the AppKit level, ahead
            // of any responder's own handling, so focus inside the overlay
            // can't swallow it.
            .background(EscapeKeyCatcher { navigator.presentedSheet = nil })
            .animation(FlotillaMotion.snappy.curve, value: navigator.presentedSheet)
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: WorkspaceSheet) -> some View {
        switch sheet {
        case .createSession(let initialGoal, let projectID):
            let targetProjectID = projectID ?? navigator.selectedProjectID
            CreateSessionView(
                store: store,
                createWorktreeByDefault: settingsViewModel.settings.sessionDefaults.createWorktreeByDefault,
                fetchBeforeCreatingWorktree: settingsViewModel.settings.git.fetchBeforeCreatingWorktree,
                initialProject: targetProjectID.flatMap { id in store.projects.first { $0.id == id } },
                initialGoal: initialGoal ?? "",
                didCreateSession: { id in
                    navigator.selection = .session(id)
                    store.selectedSessionID = id
                },
                openCodeSubscription: settingsViewModel.settings.openCodeSubscription,
                defaultAgent: AgentKind(rawValue: settingsViewModel.settings.sessionDefaults.defaultAgentRawValue) ?? .claudeCode,
                onDismiss: { navigator.presentedSheet = nil }
            )
        case .commandPalette:
            CommandPaletteView(
                projects: store.projects,
                sessions: store.sessions,
                perform: perform,
                openProject: openProject,
                openSession: openSession,
                onDismiss: { navigator.presentedSheet = nil }
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
            } else {
                Color.clear.onAppear { navigator.presentedSheet = nil }
            }
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
            navigator.restoreOverviewSelection()
        case .showProjects:
            navigator.restoreOverviewSelection()
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
            navigator.sessionLens = .changes
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
            .onChange(of: store.selectedSessionID) { _, sessionID in
                settingsViewModel.settings.workspace.selectedSessionID = sessionID?.uuidString
                navigator.selectedSessionID = sessionID
            }
            .onChange(of: navigator.selectedSessionID) { _, sessionID in
                store.selectedSessionID = sessionID
            }
            .onChange(of: store.sessions.count) {
                terminalManager.retainControllers(for: Set(store.sessions.map(\.id)))
                // Under UI testing each monitor's sub-second polling hop to
                // the main actor keeps XCUITest's quiescence check from ever
                // settling, adding ~1s to every query. Status simulation
                // launches still observe via HookCoordinator.init.
                if ProcessInfo.processInfo.environment["UI_TESTING"] != "1" {
                    hookCoordinator?.observeAll()
                }
            }
            .onChange(of: store.sessions.map(\.status)) {
                if ProcessInfo.processInfo.environment["UI_TESTING"] != "1" {
                    hookCoordinator?.observeAll()
                }
            }
            .onChange(of: settingsViewModel.settings.terminal) {
                applyTerminalPreferences()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                store.flushLiveScrollback()
            }
    }
}

/// Installs an AppKit local event monitor for the Escape key while mounted,
/// and removes it on teardown.
///
/// SwiftUI's own Escape handling (`.onExitCommand`, `.keyboardShortcut(.cancelAction)`)
/// only fires if nothing focused inside the view consumes the key first — and
/// a focused `NSTextField`/`NSTextView` routinely does exactly that via its
/// own `cancelOperation:` before either handler ever sees it. A local monitor
/// intercepts at the AppKit dispatch level, ahead of any responder's own
/// handling, so focus inside the overlay can no longer swallow it.
private struct EscapeKeyCatcher: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install(onEscape: onEscape)
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onEscape: (() -> Void)?
        private var monitor: Any?

        func install(onEscape: @escaping () -> Void) {
            self.onEscape = onEscape
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event } // kVK_Escape
                self?.onEscape?()
                return nil // Consumed — no system beep, no further propagation.
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
