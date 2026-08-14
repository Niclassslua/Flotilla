import SwiftUI
import ProcessKit
import SettingsKit
import DesignSystem

@main
struct FlotillaApp: App {
    @State private var store: AppStore
    @State private var terminalManager = TerminalManager()
    @State private var hookCoordinator: HookCoordinator
    @State private var settingsViewModel: SettingsViewModel
    @State private var startupCheck: StartupCheckViewModel

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
        let hookCoordinator = HookCoordinator(
            store: appStore,
            requestsAuthorization: !environment.isUITesting,
            notificationsEnabled: {
                settingsViewModel.settings.notifications.waitingForInputEnabled
            }
        )
        _hookCoordinator = State(initialValue: hookCoordinator)

        if environment.isUITesting,
           let sessionTitle = ProcessInfo.processInfo.environment["UI_TESTING_SIMULATE_WAITING_SESSION"] {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(750))
                appStore.simulateWaitingPromptForUITesting(sessionTitle: sessionTitle)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                store: store,
                terminalManager: terminalManager,
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
                    NotificationCenter.default.post(name: .flotillaNewSession, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Workspace") {
                Button("Projects") {
                    NotificationCenter.default.post(name: .flotillaShowProjects, object: nil)
                }
                .keyboardShortcut("1", modifiers: .command)
                Button("Sessions") {
                    NotificationCenter.default.post(name: .flotillaShowSessions, object: nil)
                }
                .keyboardShortcut("2", modifiers: .command)
                Divider()
                Button("Session Grid") {
                    NotificationCenter.default.post(name: .flotillaShowGrid, object: nil)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Command Palette…") {
                    NotificationCenter.default.post(name: .flotillaCommandPalette, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }
        .defaultSize(width: 1_280, height: 820)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(viewModel: settingsViewModel)
                .preferredColorScheme(settingsViewModel.settings.appearance.colorScheme)
                .tint(FlotillaPalette.ocean)
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
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
