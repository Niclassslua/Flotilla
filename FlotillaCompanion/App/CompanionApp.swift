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
/// - `-openFirstMac` / `-openSession <uuid>` (DEBUG): jumps straight to the
///   fleet or a session on launch, for screenshotting without navigating by hand.
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
        if let sessionIDString = value(after: "-openSession", in: arguments), let sessionID = UUID(uuidString: sessionIDString),
           let macID = store.mac(forSession: sessionID)?.id {
            store.path = [.fleet(macID), .session(sessionID)]
        }
        ProtoFlags.enabled = Set(values(after: "-proto", in: arguments))
        #endif
        return store
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// Every value following an occurrence of `flag`, for flags repeated to
    /// enable several at once (`-proto a -proto b`).
    private static func values(after flag: String, in arguments: [String]) -> [String] {
        arguments.indices.compactMap { index in
            guard arguments[index] == flag, arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
    }
}

/// UI prototypes gated behind `-proto <name>` (repeatable), so screenshot
/// comparisons don't touch shipped UI. Debug-only scaffolding for the design
/// review pass — never read outside `#if DEBUG` call sites.
///
/// See `docs/companion.md` for the list of names in flight.
@MainActor
enum ProtoFlags {
    static var enabled: Set<String> = []

    static func isOn(_ name: String) -> Bool {
        #if DEBUG
        enabled.contains(name)
        #else
        false
        #endif
    }
}

/// -proto haptics: fires `feedback` on every change to `value`, gated behind
/// the flag so it stays off by default. Device-only — `.sensoryFeedback`
/// doesn't do anything in the simulator, so this can't be screenshotted.
struct HapticsOnChange<Value: Equatable>: ViewModifier {
    let value: Value
    let feedback: SensoryFeedback

    func body(content: Content) -> some View {
        if ProtoFlags.isOn("haptics") {
            content.sensoryFeedback(feedback, trigger: value)
        } else {
            content
        }
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
    @State private var disconnectTask: Task<Void, Never>?

    /// Interactive app-switch gestures (home-indicator drag, Control Center,
    /// app-switcher peek) round-trip through `.background` in well under a
    /// second. Only tear down the Mac connection once we've stayed away long
    /// enough that this is a real backgrounding, not a passing gesture.
    private static let disconnectGrace: Duration = .seconds(2.5)

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
            switch phase {
            case .active:
                disconnectTask?.cancel()
                disconnectTask = nil
                store.setActive(true)
            case .background:
                disconnectTask?.cancel()
                disconnectTask = Task {
                    try? await Task.sleep(for: Self.disconnectGrace)
                    guard !Task.isCancelled else { return }
                    store.setActive(false)
                }
            case .inactive:
                // Transient: gestures like a home-indicator drag pass through
                // here without ever backgrounding the app. Ignore.
                break
            @unknown default:
                break
            }
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
