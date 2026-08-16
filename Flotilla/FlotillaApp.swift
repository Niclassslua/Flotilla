import SwiftUI
import ProcessKit
import SettingsKit
import DesignSystem

@main
struct FlotillaApp: App {
    @State private var store: AppStore
    @State private var terminalManager: TerminalManager
    @State private var hookCoordinator: HookCoordinator
    @State private var settingsViewModel: SettingsViewModel
    @State private var startupCheck: StartupCheckViewModel
    @State private var navigator: WorkspaceNavigator

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
            processManager: SessionProcessManager(
                locator: locator,
                processFactory: processFactory,
                settingsProvider: { settingsViewModel.settings }
            ),
            worktreeBaseDirectoryProvider: {
                let configuredPath = settingsViewModel.settings.worktreeBaseDirectory
                return configuredPath.isEmpty ? environment.worktreeBaseDirectory : URL(fileURLWithPath: configuredPath)
            }
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

        // No-op unless FLOTILLA_PERF=1 — see PerfLog.
        MainThreadStallMonitor.shared.start()

        if environment.isUITesting,
           let sessionTitle = ProcessInfo.processInfo.environment["UI_TESTING_SIMULATE_WAITING_SESSION"] {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(750))
                appStore.simulateWaitingPromptForUITesting(sessionTitle: sessionTitle)
            }
        }

        if environment.isUITesting,
           let sessionTitle = ProcessInfo.processInfo.environment["UI_TESTING_SIMULATE_CRASHED_SESSION"] {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(750))
                appStore.simulateCrashedSessionForUITesting(sessionTitle: sessionTitle)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                store: store,
                terminalManager: terminalManager,
                navigator: navigator,
                hookCoordinator: hookCoordinator,
                startupCheck: startupCheck,
                settingsViewModel: settingsViewModel
            )
            .preferredColorScheme(settingsViewModel.settings.appearance.colorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("New Session…") {
                    navigator.destination = .sessions
                    navigator.layout = .focus
                    navigator.selectedSessionID = nil
                    // The sheet presentation is handled by ContentView's sheet(item:)
                    // We'll need to trigger it differently - use a published property or similar
                    // For now, just set the destination; the new session button in the global bar handles the sheet
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Workspace") {
                Button("Overview") {
                    navigator.destination = .overview
                }
                .keyboardShortcut("1", modifiers: .command)
                Button("Sessions") {
                    navigator.destination = .sessions
                    navigator.layout = .focus
                }
                .keyboardShortcut("2", modifiers: .command)
                Button("Projects") {
                    navigator.destination = .projects
                }
                .keyboardShortcut("3", modifiers: .command)
                Divider()
                Button("Focus Layout") {
                    navigator.destination = .sessions
                    navigator.layout = .focus
                }
                .keyboardShortcut("1", modifiers: [.command, .control])
                Button("Grid Layout") {
                    navigator.destination = .sessions
                    navigator.layout = .grid
                }
                .keyboardShortcut("2", modifiers: [.command, .control])
                Button("Board Layout") {
                    navigator.destination = .sessions
                    navigator.layout = .board
                }
                .keyboardShortcut("3", modifiers: [.command, .control])
                Divider()
                Button("Terminal") {
                    navigator.destination = .sessions
                    navigator.layout = .focus
                    navigator.sessionLens = .terminal
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Files") {
                    navigator.destination = .sessions
                    navigator.layout = .focus
                    navigator.sessionLens = .files
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Instructions") {
                    navigator.destination = .sessions
                    navigator.layout = .focus
                    navigator.sessionLens = .instructions
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Toggle Changes") {
                    navigator.isChangesInspectorOpen.toggle()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Button("Command Palette…") {
                    // ContentView handles this via sheet
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
                .tint(FlotillaColors().accent)
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