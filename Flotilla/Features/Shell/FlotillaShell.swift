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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var navigator: WorkspaceNavigator
    @Bindable var store: AppStore
    let terminalManager: TerminalManager
    var hookCoordinator: HookCoordinator?
    @Bindable var startupCheck: StartupCheckViewModel
    @Bindable var settingsViewModel: SettingsViewModel
    @State var activityStore: SessionActivityStore
    @State private var createSessionProgress: CGFloat = 0

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
        // A plain `.overlay {}` on a view doesn't reliably composite as the
        // true top AppKit layer for hit-testing — clicks can fall straight
        // through to panes even though the overlay renders visually on top.
        // An explicit `ZStack` avoids that: it's SwiftUI's own stacking
        // container, so every child gets genuine, predictable z-order.
        ZStack {
            workspaceContent
                .background { uiTestWindowPlacer }
                .background { ephemeralWindowStateDisabler }
                .sheet(item: modalSheetBinding) { sheet in
                    sheetContent(sheet)
                }
            overlayPresentation
        }
        .environment(\.flotillaLiquidGlassEnabled, settingsViewModel.settings.liquidGlassEnabled)
        .background {
            LiquidGlassWindowConfigurator(isEnabled: settingsViewModel.settings.liquidGlassEnabled)
        }
        .animation(reduceMotion ? nil : FlotillaMotion.snappy.curve, value: navigator.presentedSheet)
        .task {
            await restoreWorkspaceSelection()
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

    /// Inert outside UI testing.
    @ViewBuilder
    private var uiTestWindowPlacer: some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["UI_TESTING"] == "1" {
            UITestWindowPlacer(placement: .fillPrimaryDisplay)
        }
        #endif
    }

    /// Inert outside the Ephemeral build.
    @ViewBuilder
    private var ephemeralWindowStateDisabler: some View {
#if FLOTILLA_EPHEMERAL
        // The navigator is present in every scope now, so there is no longer a
        // case where the sidebar should start hidden.
        EphemeralWindowStateDisabler(
            initialSidebarWidth: FlotillaLayoutWidth.sidebarIdeal,
            shouldShowSidebar: true
        )
#endif
    }

    /// Non-nil while the grid is the presentation on screen, which is the only
    /// context where a row's membership control means anything. It no longer
    /// changes what clicking a row does — that hijack made one gesture mean
    /// two opposite things, switched by unlabelled state.
    var gridMembership: GridMembership? {
        guard navigator.selection.isCollection, navigator.presentation == .grid else { return nil }
        let dimensions = GridDimensions(
            columns: settingsViewModel.settings.workspace.gridColumnCount,
            rows: settingsViewModel.settings.workspace.gridRowCount
        )
        return GridMembership(
            memberIDs: GridSelection.memberIDs(
                selectedIDs: settingsViewModel.settings.workspace.gridSelectedSessionIDs,
                in: store.sessions
            ),
            onToggle: { id in
                settingsViewModel.toggleGridMembership(of: id, in: store.sessions, capacity: dimensions.capacity)
            }
        )
    }

    /// `FleetSessionList`'s `List` binds `Set<SidebarItem>` natively, so
    /// AppKit's table view handles ⌘/Shift-click range selection itself —
    /// this only has to react to the *result*. A click, arrow key, or
    /// programmatic change that narrows the set to one tag opens it. A set
    /// with more than one tag is a batch selection: it changes nothing in
    /// the detail column, leaving `Delete`/`Backspace` (see
    /// `FleetSessionList.onDeleteCommand`) as the only thing that acts on it
    /// for now.
    ///
    /// While the grid is the presentation, clicking a session row assigns or
    /// unassigns it instead of opening it — there is no reason to leave the
    /// grid just to build it.
    ///
    /// This is the gesture the audit filed as a P0, and it is deliberately
    /// back. What made it a defect was not the shortcut itself but that
    /// nothing said which mode you were in or what a click had just done: the
    /// only cue was a green tint matching the `Working` status text two lines
    /// below it. Membership is drawn on the row now — a border with a corner
    /// checkmark — so the gesture has a visible result, and double-click (see
    /// `SessionSidebarRow`) still opens the session.
    func handleSidebarSelectionChange(_ newSelection: Set<SidebarItem>) {
        guard newSelection.count == 1, let only = newSelection.first else { return }
        if let gridMembership, case .session(let id) = only {
            gridMembership.onToggle(id)
            return
        }
        guard only != navigator.selection else { return }
        switch only {
        case .session(let id):
            navigator.selection = .session(id)
            store.selectedSessionID = id
        case .overview, .allSessions, .smartList, .project:
            navigator.selection = only
        }
    }

    /// The primary workspace layout: one navigator, always present, beside the
    /// detail column.
    ///
    /// A real `NavigationSplitView` rather than the hand-rolled `HStack` this
    /// replaces. That `HStack` mounted the sidebar only in the Sessions facet,
    /// so the window's left edge reflowed on every scope switch, and it gave
    /// up everything the platform provides for free: ⌃⌘S collapse, the toolbar
    /// sidebar toggle, native column resize, and width autosave. It also meant
    /// `EphemeralWindowStateDisabler` searched by autosave name for a split
    /// view the window never created.
    private var workspaceContent: some View {
        NavigationSplitView(columnVisibility: $navigator.columnVisibility) {
            SessionsSidebar(
                store: store,
                selection: $navigator.sidebarSelection,
                searchText: $navigator.searchText,
                isHomeSelected: navigator.selection == .overview,
                onSelectHome: { navigator.showHomeDashboard() },
                onOpenSession: { id in
                    navigator.selection = .session(id)
                    store.selectedSessionID = id
                },
                onRequestDelete: { navigator.presentedSheet = .deleteSession($0) },
                onCreateSession: { presentCreateSession() },
                onCreateSessionFromIssue: store.ghService == nil ? nil : { presentCreateSessionFromIssue(projectID: $0) },
                gridMembership: gridMembership
            )
            .navigationSplitViewColumnWidth(
                min: FlotillaLayoutWidth.sidebarMin,
                ideal: FlotillaLayoutWidth.sidebarIdeal,
                max: FlotillaLayoutWidth.sidebarMax
            )
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
                onCreateSession: { presentCreateSession() },
                onCommandPalette: { navigator.presentedSheet = .commandPalette }
            )
            // A plain `.frame(minWidth:)` here reports a fixed ideal size to
            // `NavigationSplitView`'s own layout negotiation instead of
            // letting it keep stretching the column — which left a blank
            // strip at the window's trailing edge once the sidebar was
            // dragged wide enough that the leftover space stopped matching
            // that ideal. `navigationSplitViewColumnWidth` is the column-sizing
            // API the split view itself balances against.
            .navigationSplitViewColumnWidth(min: FlotillaLayoutWidth.detailMin, ideal: FlotillaLayoutWidth.detailIdeal)
            // Declared on the detail column rather than on the `ZStack` that
            // wraps the whole split view. From outside the `NavigationSplitView`
            // SwiftUI resolves every `ToolbarSpacer` against the *sidebar*
            // toolbar section, so both of `WorkspaceToolbar`'s spacers were
            // hoisted ahead of the sidebar toggle — the fixed gap never
            // separated the wordmark from the history controls, and the
            // flexible one had nothing to its left to push against, leaving the
            // four global actions packed against Forward mid-window. Declared
            // here, the spacers land in the detail section in declaration
            // order and the flexible one takes up the slack.
            .toolbar {
                WorkspaceToolbar(
                    navigator: navigator,
                    store: store,
                    settingsViewModel: settingsViewModel,
                    onCommandPalette: { navigator.presentedSheet = .commandPalette }
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        // In glass mode the toolbar's own opaque band and separator are what
        // kept its controls from reading as Liquid Glass: they floated over a
        // flat strip instead of the columns' glass, which now extends under it.
        .toolbarBackgroundVisibility(
            settingsViewModel.settings.liquidGlassEnabled ? .hidden : .automatic,
            for: .windowToolbar
        )
        .environment(\.workspaceNavigator, navigator)
        .frame(minWidth: FlotillaLayoutWidth.windowMin, minHeight: FlotillaLayoutWidth.windowHeightMin)
        .onChange(of: navigator.sidebarSelection) { _, newSelection in
            handleSidebarSelectionChange(newSelection)
        }
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

    private var isCreateSessionPresented: Bool {
        if case .createSession? = navigator.presentedSheet { return true }
        return false
    }

    private func presentCreateSession() {
        createSessionProgress = reduceMotion ? 1 : 0
        navigator.presentedSheet = .createSession
    }

    /// The launcher with its issue picker open, for `projectID` — or, from the
    /// palette, the project in view or the selected session's project.
    private func presentCreateSessionFromIssue(projectID: UUID?) {
        createSessionProgress = reduceMotion ? 1 : 0
        let target = projectID ?? navigator.selectedProjectID ?? store.selectedSession?.projectID
        navigator.presentedSheet = .createSession(projectID: target, opensIssuePicker: true)
    }

    private func scheduleCreateSessionEntrance(after delay: Duration) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard isCreateSessionPresented, createSessionProgress == 0 else { return }
            withAnimation(.snappy(duration: 0.26)) {
                createSessionProgress = 1
            }
        }
    }

    private func dismissCreateSession() {
        if reduceMotion {
            navigator.presentedSheet = nil
            createSessionProgress = 0
            return
        }
        withAnimation(.easeIn(duration: 0.18), completionCriteria: .logicallyComplete) {
            createSessionProgress = 0
        } completion: {
            navigator.presentedSheet = nil
        }
    }

    private func dismissOverlay() {
        if isCreateSessionPresented {
            dismissCreateSession()
            return
        }
        withAnimation(reduceMotion ? nil : FlotillaMotion.snappy.curve) {
            navigator.presentedSheet = nil
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
                    .fill(Color.black.opacity(0.55 * (isCreateSessionPresented ? createSessionProgress : 1)))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismissOverlay() }
                    .transition(.opacity)

                overlaySheetContent(sheet)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Absorb clicks inside the sheet content so they don't fall through to the backdrop
                    }
            }
            .zIndex(1)
            .transition(isCreateSessionPresented ? .identity : .opacity)
            .onExitCommand { dismissOverlay() }
            // Belt and suspenders: `.onExitCommand`/`.keyboardShortcut(.cancelAction)`
            // only fire if nothing focused inside the overlay consumes Escape
            // first — and a focused NSTextField/NSTextView's own `cancelOperation:`
            // handling can do exactly that before either ever sees the key. A
            // local event monitor intercepts Escape at the AppKit level, ahead
            // of any responder's own handling, so focus inside the overlay
            // can't swallow it.
            .background(EscapeKeyCatcher { dismissOverlay() })
        }
    }

    @ViewBuilder
    private func overlaySheetContent(_ sheet: WorkspaceSheet) -> some View {
        if case .createSession = sheet {
            createSessionAnimatedContent(sheet)
                .transition(.identity)
        } else {
            sheetContent(sheet)
                .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
    }

    private func createSessionAnimatedContent(_ sheet: WorkspaceSheet) -> some View {
        let remaining = 1 - createSessionProgress
        return sheetContent(sheet)
            .opacity(Double(createSessionProgress))
            .scaleEffect(1 - 0.12 * remaining)
            .offset(y: 54 * remaining)
            .onAppear {
                // Commit the starting transform before animating its progress.
                if reduceMotion { createSessionProgress = 1 }
                else { scheduleCreateSessionEntrance(after: .milliseconds(50)) }
            }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: WorkspaceSheet) -> some View {
        switch sheet {
        case .createSession(let initialGoal, let projectID, let opensIssuePicker, let issueNumber):
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
                opensIssuePicker: opensIssuePicker == true,
                initialIssueNumber: issueNumber,
                onDismiss: { dismissOverlay() }
            )
        case .commandPalette:
            CommandPaletteView(
                projects: store.projects,
                sessions: store.sessions,
                perform: perform,
                openProject: openProject,
                openSession: openSession,
                handoffTargets: store.selectedSession.map { store.handoffTargets(for: $0) } ?? [],
                onHandoff: { target in
                    if let sessionID = store.selectedSession?.id {
                        Task { await store.handoffSession(sessionID: sessionID, to: target) }
                    }
                },
                onDismiss: { dismissOverlay() }
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
                    isRunning: store.process(for: sessionID) != nil,
                    defaultDeleteWorktree: settingsViewModel.settings.git.worktreeOnSessionDelete.deletesWorktree,
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
        // Ensure the app always starts on the Home page.
        navigator.selection = .overview
        navigator.sidebarSelection = []
        store.selectedSessionID = nil
        settingsViewModel.settings.workspace.selectedSessionID = nil
        // The group is what the grid and board are filtered to, so restoring
        // it is what makes the bar's chip agree with the tiles on relaunch.
        // `SessionGroup.init(rawValue:)` falls back to `.all` for a project
        // that no longer exists.
        navigator.sessionGroup = SessionGroup(
            rawValue: settingsViewModel.settings.workspace.sessionGroup
        )
        navigator.pruneSessionGroup(against: Set(store.projects.map(\.id)))
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
            gpuRendering: preferences.gpuRendering,
            backgroundOpacity: settingsViewModel.settings.liquidGlassEnabled ? preferences.backgroundOpacity : 1
        )
    }

    private func perform(_ command: WorkspaceCommand) {
        switch command {
        case .newSession:
            presentCreateSession()
        case .newSessionFromIssue:
            presentCreateSessionFromIssue(projectID: nil)
        case .showHome:
            navigator.restoreHomeSelection()
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
            // Opens the selected session, which is what the command says it
            // does. It used to navigate to the fleet — indistinguishable from
            // `.showSessions` — so the palette offered two labels for one
            // outcome and neither did what "Open Terminal" implies.
            if let sessionID = store.selectedSessionID {
                openSession(sessionID)
            } else {
                navigator.selection = .allSessions
                navigator.presentation = .focus
            }
        case .showFiles:
            navigator.openProjectPanel(.files, scopedTo: store.selectedSession)
        case .showInstructions:
            navigator.openProjectPanel(.rules, scopedTo: store.selectedSession)
        case .showChanges:
            navigator.openProjectPanel(.git, scopedTo: store.selectedSession)
        case .restoreSessions:
            navigator.presentedSheet = .restore
        case .showSettings:
            openSettings()
        case .showShortcuts:
            navigator.presentedSheet = .shortcuts
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
            .onChange(of: navigator.sessionGroup) { _, group in
                settingsViewModel.settings.workspace.sessionGroup = group.rawValue
            }
            // A deleted project must not leave the fleet filtered to a group
            // whose chip is no longer in the bar to explain the emptiness.
            .onChange(of: store.projects.map(\.id)) { _, ids in
                navigator.pruneSessionGroup(against: Set(ids))
            }
            .onChange(of: store.selectedSessionID) { _, sessionID in
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
            .onChange(of: settingsViewModel.settings.liquidGlassEnabled) {
                // Disabling glass also returns every active terminal renderer
                // to an opaque canvas; do not make the user reopen sessions.
                applyTerminalPreferences()
            }
            // Running agents read their attribution mode, title and prompt at
            // commit time, so both kinds of change are pushed to them.
            .onChange(of: settingsViewModel.settings.git) {
                store.commitAttribution.refreshPayloads(for: store.sessions)
            }
            .onChange(of: store.sessions.map(\.title)) {
                store.commitAttribution.refreshPayloads(for: store.sessions)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                store.shutdown()
            }
    }
}

/// Installs an AppKit local event monitor for the Escape key while mounted,
/// and removes it on teardown.
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
