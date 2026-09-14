import SwiftUI
import DesignSystem
import CompanionKit

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

/// Builds the store for this launch.
///
/// - Default: real Macs over the network (`RemoteCompanionDataSource`).
/// - `-demo`: the fixture fleet, for UI work without a Mac. `-scenario <name>`
///   implies the demo and boots into a scripted state.
/// - `-pairingLink <link>` (DEBUG): opens pairing with that link, for
///   end-to-end runs in the simulator, which has no camera.
@MainActor
enum CompanionEnvironment {
    static func makeStore(arguments: [String] = ProcessInfo.processInfo.arguments) -> CompanionStore {
        let scenario = value(after: "-scenario", in: arguments).flatMap(Scenario.init(rawValue:))
        let isDemo = arguments.contains("-demo") || scenario != nil
        let data: any CompanionDataSource = isDemo ? MockCompanionDataSource() : RemoteCompanionDataSource()
        let defaults = isDemo ? (UserDefaults(suiteName: "companion.demo") ?? .standard) : .standard
        let store = CompanionStore(data: data, defaults: defaults)
        if let scenario {
            store.run(scenario)
        } else {
            store.restoreLastMac()
        }
        #if DEBUG
        store.incomingPairingLink = value(after: "-pairingLink", in: arguments)
        if arguments.contains("-openFirstMac"), let first = store.macs.first {
            store.path = [.fleet(first.id)]
        }
        #endif
        return store
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
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
    @Environment(\.scenePhase) private var scenePhase

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
        .onChange(of: scenePhase, initial: true) { _, phase in
            store.setActive(phase == .active)
        }
        .onOpenURL { url in
            guard url.scheme == PairingPayload.scheme, store.supportsPairing else { return }
            store.incomingPairingLink = url.absoluteString
        }
        .sheet(isPresented: Binding(
            get: { store.incomingPairingLink != nil },
            set: { if !$0 { store.incomingPairingLink = nil } }
        )) {
            PairMacView(initialLink: store.incomingPairingLink) { macID in
                store.path = [.fleet(macID)]
            }
        }
        .alert(
            "Couldn't Complete That",
            isPresented: Binding(get: { store.actionError != nil }, set: { if !$0 { store.actionError = nil } }),
            presenting: store.actionError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
    }
}
