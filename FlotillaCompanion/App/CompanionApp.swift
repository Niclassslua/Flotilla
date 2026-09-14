import SwiftUI
import DesignSystem

@main
struct CompanionApp: App {
    @State private var store = CompanionEnvironment.makeStore()
    @AppStorage(AppearanceSetting.storageKey) private var appearance: AppearanceSetting = .system

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(appearance.colorScheme)
                // Orange is reserved for primary actions, so ordinary chrome
                // (back buttons, toolbar items) takes the text colour instead.
                .tint(FlotillaColors.textPrimary)
        }
    }
}

/// Builds the store for this launch. The prototype always runs on simulated
/// data; `-scenario <name>` boots straight into one of the scripted states.
@MainActor
enum CompanionEnvironment {
    static func makeStore(arguments: [String] = ProcessInfo.processInfo.arguments) -> CompanionStore {
        let store = CompanionStore(data: MockCompanionDataSource())
        if let flag = arguments.firstIndex(of: "-scenario"),
           arguments.indices.contains(flag + 1),
           let scenario = Scenario(rawValue: arguments[flag + 1]) {
            store.run(scenario)
        } else {
            store.restoreLastMac()
        }
        return store
    }
}

enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    static let storageKey = "companion.appearance"

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .dark: "Dark"
        case .light: "Light"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}

struct RootView: View {
    @Environment(CompanionStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationStack(path: $store.path) {
            MacsView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .fleet(let macID):
                        FleetView(macID: macID)
                    case .session(let id):
                        SessionDetailView(sessionID: id)
                    case .diff(let id, let commitHash, let focusPath):
                        DiffView(sessionID: id, commitHash: commitHash, focusPath: focusPath)
                    case .commits(let id):
                        CommitsView(sessionID: id)
                    case .file(let id, let path):
                        FileViewer(sessionID: id, path: path)
                    }
                }
        }
        .background(FlotillaColors.canvas)
    }
}
