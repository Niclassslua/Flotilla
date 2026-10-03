import SwiftUI
import AppKit
import UserNotifications
import GitKit
import ProcessKit
import SessionKit
import SettingsKit
import DesignSystem
import HooksKit
import os

@main
struct FlotillaApp: App {
    @State private var store: AppStore
    @State private var terminalManager: TerminalManager
    @State private var hookCoordinator: HookCoordinator
    @State private var settingsViewModel: SettingsViewModel
    @State private var startupCheck: StartupCheckViewModel
    @State private var navigator: WorkspaceNavigator
    @State private var notificationDelegate: FlotillaNotificationDelegate
    @State private var companionHost: CompanionHost
    @State private var dockBadge: DockBadgeController
    @Environment(\.openWindow) private var openWindow

    /// Held so the review scene — which is not a descendant of the shell and
    /// therefore inherits nothing from it — can build its own view model.
    private let gitService: any GitServiceProtocol
    private let sessionRepository: any SessionRepository
    private let foregroundNotificationGate: OSAllocatedUnfairLock<Bool>
    /// UI tests query the app's own windows and menus; a status item would be
    /// extra system-wide chrome they neither need nor control.
    private let showsMenuBarExtra: Bool

    /// Named so surfaces outside the window — the menu bar extra — can reopen
    /// the workspace after it has been closed.
    static let mainWindowSceneID = "main"

    private static let isBoardDemo = ProcessInfo.processInfo.environment["FLOTILLA_DEMO_DATA"] == "1"

    @_silgen_name("InstallViewBridgeCrashGuard")
    private static func installViewBridgeCrashGuard()

    init() {
#if FLOTILLA_EPHEMERAL
        // AppKit creates its split-view and window autosave keys before the
        // SwiftUI content is interactive. Clear this build's isolated domain
        // first so no stale geometry can influence the initial layout; the
        // EphemeralWindowStateDisabler then prevents those keys being saved
        // again once the native views exist.
        UserDefaults.standard.removePersistentDomain(forName: "com.niclassslua.flotilla.ephemeral")
#endif

        Self.installViewBridgeCrashGuard()

        // Flotilla is a single-window workspace app with its own navigation
        // model; suppress AppKit's automatic window tabbing so the View menu
        // never shows "Show Tab Bar" / "Show All Tabs".
        NSWindow.allowsAutomaticWindowTabbing = false

        let environment = AppEnvironment()
        let settingsStore: any SettingsStoring
#if FLOTILLA_EPHEMERAL
        settingsStore = EphemeralSettingsStore(
            defaultWorktreeBaseDirectory: environment.worktreeBaseDirectory.path
        )
#else
        if environment.isUITesting {
            // A unique suite prevents one UI-test launch from leaking layout,
            // paths, or appearance into another launch or the user's app.
            let defaults = UserDefaults(suiteName: "FlotillaUITests-\(ProcessInfo.processInfo.processIdentifier)")!
            settingsStore = UserDefaultsSettingsStore(
                defaults: defaults,
                defaultWorktreeBaseDirectory: environment.worktreeBaseDirectory.path
            )
        } else {
            settingsStore = UserDefaultsSettingsStore(
                defaultWorktreeBaseDirectory: environment.worktreeBaseDirectory.path
            )
        }
#endif
        let settingsViewModel = SettingsViewModel(store: settingsStore)
        _settingsViewModel = State(initialValue: settingsViewModel)
        let locator: any ExecutableLocating = environment.isUITesting
            ? UITestExecutableLocator()
            : PATHExecutableLocator()
        let processFactory: any PTYProcessCreating = environment.isUITesting
            ? MockPTYProcessFactory(echoesInput: true)
            : SystemPTYProcessFactory()

        let processManager = SessionProcessManager(
            locator: locator,
            processFactory: processFactory,
            settingsProvider: { settingsViewModel.settings }
        )
        processManager.preparesCompanionRuntimes = !environment.isUITesting
        let appStore = AppStore(
            repository: environment.sessionRepository,
            gitService: environment.gitService,
            ghService: environment.ghService,
            processManager: processManager,
            worktreeBaseDirectoryProvider: {
                let configuredPath = settingsViewModel.settings.worktreeBaseDirectory
                return configuredPath.isEmpty ? environment.worktreeBaseDirectory : URL(fileURLWithPath: configuredPath)
            },
            settingsProvider: { settingsViewModel.settings },
            nameGenerator: environment.isUITesting ? nil : AppleIntelligenceSessionNameGenerator()
        )
        appStore.lastOperationError = environment.startupWarning
        settingsViewModel.deleteLocalAttributionRecords = { [appStore] in
            appStore.commitAttribution.deleteLocalRecords()
        }
        _store = State(initialValue: appStore)
        if Self.isBoardDemo {
            BoardDemoFixtures.seedPermissions(into: appStore.permissionLogStore)
            BoardDemoFixtures.seedCI(into: appStore.ciStatusStore)
        }
        _startupCheck = State(initialValue: StartupCheckViewModel(
            settings: settingsViewModel.settings,
            locator: locator
        ))
        let terminalManager = TerminalManager()
        _terminalManager = State(initialValue: terminalManager)
        let hookCoordinator = HookCoordinator(
            store: appStore,
            screenReader: SessionScreenReader(
                terminalManager: terminalManager,
                tmuxExecutable: locator.locate("tmux")
            ),
            requestsAuthorization: !environment.isUITesting,
            isConfiguredToNotify: {
                settingsViewModel.settings.notifications.isConfiguredToNotify
            },
            notificationsEnabled: {
                let isActive = NSApp?.isActive ?? true
                return settingsViewModel.settings.notifications.shouldNotifyWaitingForInput(isActive: isActive)
            }
        )
        _hookCoordinator = State(initialValue: hookCoordinator)

        let navigator = WorkspaceNavigator()
        _navigator = State(initialValue: navigator)

        let foregroundGate = OSAllocatedUnfairLock(initialState: settingsViewModel.settings.notifications.delivery == .always)
        foregroundNotificationGate = foregroundGate

        let notificationDelegate = FlotillaNotificationDelegate(
            navigator: navigator,
            onReply: { sessionID, text in
                appStore.process(for: sessionID)?.send(input: Data((text + "\n").utf8))
            },
            shouldPresentInForeground: {
                foregroundGate.withLock { $0 }
            }
        )
        UNUserNotificationCenter.current().delegate = notificationDelegate
        _notificationDelegate = State(initialValue: notificationDelegate)

        gitService = environment.gitService
        sessionRepository = environment.sessionRepository
        _companionHost = State(initialValue: CompanionHost(
            store: appStore,
            gitService: environment.gitService,
            screenReader: environment.isUITesting ? nil : hookCoordinator.screenReader,
            defaults: environment.isUITesting ? UserDefaults(suiteName: "FlotillaUITests-companion-\(ProcessInfo.processInfo.processIdentifier)")! : .standard,
            openCodeSubscription: { settingsViewModel.settings.openCodeSubscription }
        ))

        appStore.onSessionFinished = { session in
            let isActive = NSApp?.isActive ?? true
            guard settingsViewModel.settings.notifications.shouldNotifySessionFinished(isActive: isActive) else { return }
            Task {
                await SystemNotificationDispatcher().notifySessionFinished(sessionTitle: session.title, sessionID: session.id)
            }
        }

        appStore.ciStatusStore.onFailure = { session, check in
            let isActive = NSApp?.isActive ?? true
            guard settingsViewModel.settings.notifications.shouldNotifyCIFailed(isActive: isActive) else { return }
            Task {
                await SystemNotificationDispatcher().notifyCIFailed(sessionTitle: session.title, checkName: check.name, sessionID: session.id)
            }
        }
        // Never from a test host: unit tests launch this app around them, and
        // polling would send real `gh` requests for the user's sessions.
        if !environment.isUITesting && !Self.isBoardDemo && NSClassFromString("XCTestCase") == nil {
            appStore.ciStatusStore.start()
        }

        let dockBadge = DockBadgeController(
            sessions: { appStore.sessions },
            ciFailing: { appStore.ciStatusStore.failingSessionIDs },
            isEnabled: { settingsViewModel.settings.notifications.dockBadgeEnabled }
        )
        dockBadge.start()
        _dockBadge = State(initialValue: dockBadge)
        showsMenuBarExtra = !environment.isUITesting

        // No-op unless FLOTILLA_PERF=1 — see PerfLog.
        MainThreadStallMonitor.shared.start()

        if environment.isUITesting,
           let sessionTitle = ProcessInfo.processInfo.environment["UI_TESTING_SIMULATE_WAITING_SESSION"] {
            appStore.simulateWaitingPromptForUITesting(sessionTitle: sessionTitle)
        }

        if environment.isUITesting,
           let sessionTitle = ProcessInfo.processInfo.environment["UI_TESTING_SIMULATE_CRASHED_SESSION"] {
            appStore.simulateCrashedSessionForUITesting(sessionTitle: sessionTitle)
        }

        if environment.isUITesting,
           let sessionTitle = ProcessInfo.processInfo.environment["UI_TESTING_SIMULATE_AGENT_EXIT"] {
            appStore.simulateAgentExitForUITesting(sessionTitle: sessionTitle)
            if let session = appStore.sessions.first(where: { $0.title == sessionTitle }) {
                navigator.selection = .session(session.id)
            }
        }

        // The review fixture has no live agent process, so its focused
        // surface is otherwise just a session bar over "Session Not
        // Running" — real, but easy to mistake for "there's nothing here"
        // when the Review action is a small icon in that bar. Land there
        // directly rather than making a manual run hunt through the sidebar.
        if environment.isUITesting,
           ProcessInfo.processInfo.environment["UI_TESTING_SIMULATE_REVIEW_SESSION"] == "1",
           let reviewSession = appStore.sessions.first(where: { $0.title == AppEnvironment.uiTestReviewSessionTitle }) {
            navigator.selection = .session(reviewSession.id)
        }
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowSceneID) {
            FlotillaShell(
                store: store,
                terminalManager: terminalManager,
                navigator: navigator,
                hookCoordinator: hookCoordinator,
                startupCheck: startupCheck,
                settingsViewModel: settingsViewModel,
                // The demo fleet has no live PTYs, so the real screen
                // reader would report nothing and every card's output line
                // would render empty.
                screenReader: Self.isBoardDemo
                    ? BoardDemoScreenReader()
                    : hookCoordinator.screenReader
            )
            .preferredColorScheme(settingsViewModel.settings.appearance.colorScheme)
            .environment(\.editorFontSize, settingsViewModel.settings.terminal.editorFontSize)
            .onChange(of: settingsViewModel.settings.notifications.delivery) { _, delivery in
                foregroundNotificationGate.withLock { $0 = (delivery == .always) }
            }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
#if FLOTILLA_EPHEMERAL
        .restorationBehavior(.disabled)
#endif
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session…") {
                    navigator.presentedSheet = .createSession
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Workspace") {
                Button("Back") { navigator.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!navigator.canGoBack)
                Button("Forward") { navigator.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!navigator.canGoForward)
                Divider()
                Button("Home") {
                    navigator.restoreHomeSelection()
                }
                .keyboardShortcut("1", modifiers: .command)
                Button("All Sessions") {
                    navigator.selection = .allSessions
                    navigator.presentation = .focus
                }
                .keyboardShortcut("2", modifiers: .command)
                Divider()
                ForEach(FleetSmartList.allCases) { list in
                    Button(list.title) {
                        navigator.selection = .smartList(list)
                    }
                }
                Divider()
                Button("Focus Layout") {
                    navigator.selection = .allSessions
                    navigator.presentation = .focus
                }
                .keyboardShortcut("1", modifiers: [.command, .control])
                Button("Grid Layout") {
                    navigator.selection = .allSessions
                    navigator.presentation = .grid
                }
                .keyboardShortcut("2", modifiers: [.command, .control])
                Button("Board Layout") {
                    navigator.selection = .allSessions
                    navigator.presentation = .board
                }
                .keyboardShortcut("3", modifiers: [.command, .control])
                Divider()
                Button("Review\u{2026}") {
                    if let session = store.selectedSession {
                        openWindow(id: SessionReviewWindow.sceneID, value: session.id)
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.selectedSession?.status != .readyForReview)
                Button("Changes") {
                    navigator.openProjectPanel(.git, scopedTo: store.selectedSession)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Files") {
                    navigator.openProjectPanel(.files, scopedTo: store.selectedSession)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Instructions") {
                    navigator.openProjectPanel(.rules, scopedTo: store.selectedSession)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("Previous Session") {
                    let sorted = store.sessions.sorted(by: { $0.lastActiveAt > $1.lastActiveAt })
                    guard !sorted.isEmpty else { return }
                    if let currentID = store.selectedSessionID,
                       let index = sorted.firstIndex(where: { $0.id == currentID }) {
                        let prevIndex = (index - 1 + sorted.count) % sorted.count
                        let target = sorted[prevIndex]
                        navigator.selection = .session(target.id)
                        store.selectedSessionID = target.id
                    } else if let first = sorted.first {
                        navigator.selection = .session(first.id)
                        store.selectedSessionID = first.id
                    }
                }
                .keyboardShortcut("[", modifiers: [.command, .option])
                Button("Next Session") {
                    let sorted = store.sessions.sorted(by: { $0.lastActiveAt > $1.lastActiveAt })
                    guard !sorted.isEmpty else { return }
                    if let currentID = store.selectedSessionID,
                       let index = sorted.firstIndex(where: { $0.id == currentID }) {
                        let nextIndex = (index + 1) % sorted.count
                        let target = sorted[nextIndex]
                        navigator.selection = .session(target.id)
                        store.selectedSessionID = target.id
                    } else if let first = sorted.first {
                        navigator.selection = .session(first.id)
                        store.selectedSessionID = first.id
                    }
                }
                .keyboardShortcut("]", modifiers: [.command, .option])
                Divider()
                Button("Restart Session") {
                    if let session = store.selectedSession {
                        store.restartSession(sessionID: session.id)
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("Delete Session…") {
                    if let session = store.selectedSession {
                        navigator.presentedSheet = .deleteSession(session.id)
                    }
                }
                .keyboardShortcut(.delete, modifiers: .command)
                Divider()
                Button("Command Palette…") {
                    navigator.presentedSheet = .commandPalette
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }
        .defaultSize(width: 1_280, height: 820)
        .windowResizability(.contentMinSize)

        // A second window, not a panel in the shell: reviewing a diff is a
        // whole-screen activity, and a review outlives navigating the fleet.
        // Keyed by session ID so re-opening a session under review raises the
        // window it already has rather than making another.
        WindowGroup(id: SessionReviewWindow.sceneID, for: UUID.self) { $reviewedSessionID in
            if let reviewedSessionID {
                SessionReviewWindow(
                    sessionID: reviewedSessionID,
                    store: store,
                    gitService: gitService,
                    repository: sessionRepository
                )
                .preferredColorScheme(settingsViewModel.settings.appearance.colorScheme)
            }
        }
        .defaultSize(width: 1280, height: 860)
#if FLOTILLA_EPHEMERAL
        .restorationBehavior(.disabled)
#endif

        MenuBarExtra(isInserted: menuBarExtraInserted) {
            FleetMenuBarMenu(store: store, navigator: navigator)
        } label: {
            FleetMenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(viewModel: settingsViewModel)
                .preferredColorScheme(settingsViewModel.settings.appearance.colorScheme)
                .environment(navigator)
                .environment(companionHost)
                .tint(FlotillaColors.accent)
        }
        .defaultSize(width: 800, height: 620)
#if FLOTILLA_EPHEMERAL
        .restorationBehavior(.disabled)
#endif
    }
}

extension FlotillaApp {
    /// Written back into the setting so that if the system removes the item,
    /// Settings shows it as off rather than disagreeing with the menu bar.
    private var menuBarExtraInserted: Binding<Bool> {
        Binding(
            get: { showsMenuBarExtra && settingsViewModel.settings.notifications.menuBarExtraEnabled },
            set: { newValue in
                guard showsMenuBarExtra else { return }
                settingsViewModel.settings.notifications.menuBarExtraEnabled = newValue
            }
        )
    }
}

private struct UITestExecutableLocator: ExecutableLocating {
    func locate(_ name: String) -> URL? {
        URL(fileURLWithPath: "/usr/bin/env")
    }
}

extension AppearanceMode {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
