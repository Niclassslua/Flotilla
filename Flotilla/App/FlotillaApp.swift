import SwiftUI
import UserNotifications
import ProcessKit
import SettingsKit
import DesignSystem
import HooksKit

@main
struct FlotillaApp: App {
    @State private var store: AppStore
    @State private var terminalManager: TerminalManager
    @State private var hookCoordinator: HookCoordinator
    @State private var settingsViewModel: SettingsViewModel
    @State private var startupCheck: StartupCheckViewModel
    @State private var navigator: WorkspaceNavigator
    @State private var notificationDelegate: FlotillaNotificationDelegate

    init() {
        let environment = AppEnvironment()
        let settingsStore: UserDefaultsSettingsStore
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
        let settingsViewModel = SettingsViewModel(store: settingsStore)
        _settingsViewModel = State(initialValue: settingsViewModel)
        let locator: any ExecutableLocating = environment.isUITesting
            ? UITestExecutableLocator()
            : PATHExecutableLocator()
        let processFactory: any PTYProcessCreating = environment.isUITesting
            ? MockPTYProcessFactory(echoesInput: true)
            : SystemPTYProcessFactory()

        let appStore = AppStore(
            repository: environment.sessionRepository,
            gitService: environment.gitService,
            ghService: environment.ghService,
            processManager: SessionProcessManager(
                locator: locator,
                processFactory: processFactory,
                settingsProvider: { settingsViewModel.settings }
            ),
            worktreeBaseDirectoryProvider: {
                let configuredPath = settingsViewModel.settings.worktreeBaseDirectory
                return configuredPath.isEmpty ? environment.worktreeBaseDirectory : URL(fileURLWithPath: configuredPath)
            },
            settingsProvider: { settingsViewModel.settings }
        )
        appStore.lastOperationError = environment.startupWarning
        _store = State(initialValue: appStore)
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
            notificationsEnabled: {
                settingsViewModel.settings.notifications.waitingForInputEnabled
            }
        )
        _hookCoordinator = State(initialValue: hookCoordinator)

        let navigator = WorkspaceNavigator()
        _navigator = State(initialValue: navigator)

        let notificationDelegate = FlotillaNotificationDelegate(
            navigator: navigator,
            onReply: { sessionID, text in
                appStore.process(for: sessionID)?.send(input: Data((text + "\n").utf8))
            }
        )
        UNUserNotificationCenter.current().delegate = notificationDelegate
        _notificationDelegate = State(initialValue: notificationDelegate)

        appStore.onSessionFinished = { session in
            guard settingsViewModel.settings.notifications.finishedEnabled else { return }
            Task {
                await SystemNotificationDispatcher().notifySessionFinished(sessionTitle: session.title, sessionID: session.id)
            }
        }

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
    }

    var body: some Scene {
        WindowGroup {
            FlotillaShell(
                store: store,
                terminalManager: terminalManager,
                navigator: navigator,
                hookCoordinator: hookCoordinator,
                startupCheck: startupCheck,
                settingsViewModel: settingsViewModel,
                screenReader: hookCoordinator.screenReader
            )
            .preferredColorScheme(settingsViewModel.settings.appearance.colorScheme)
        }
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("New Session…") {
                    navigator.presentedSheet = .createSession
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Workspace") {
                Button("Overview") {
                    navigator.restoreOverviewSelection()
                }
                .keyboardShortcut("1", modifiers: .command)
                Button("All Sessions") {
                    navigator.selection = .allSessions
                    navigator.presentation = .focus
                }
                .keyboardShortcut("2", modifiers: .command)
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
                Button("Terminal") {
                    navigator.selection = .allSessions
                    navigator.presentation = .focus
                    navigator.sessionLens = .terminal
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Changes") {
                    navigator.selection = .allSessions
                    navigator.presentation = .focus
                    navigator.sessionLens = .changes
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Files") {
                    navigator.selection = .allSessions
                    navigator.presentation = .focus
                    navigator.sessionLens = .files
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Instructions") {
                    navigator.selection = .allSessions
                    navigator.presentation = .focus
                    navigator.sessionLens = .instructions
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

        Settings {
            SettingsView(viewModel: settingsViewModel)
                .preferredColorScheme(settingsViewModel.settings.appearance.colorScheme)
                .environment(navigator)
                .tint(FlotillaColors.accent)
        }
        .defaultSize(width: 800, height: 620)
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
