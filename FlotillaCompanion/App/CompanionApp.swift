import SwiftUI
import DesignSystem
import CompanionKit

#if !os(iOS)
public enum NavigationBarTitleDisplayMode: Sendable { case inline, automatic, large }
public extension View {
    func navigationBarTitleDisplayMode(_ mode: NavigationBarTitleDisplayMode) -> some View { self }
}
public extension ToolbarItemPlacement {
    static var topBarTrailing: ToolbarItemPlacement { .automatic }
    static var topBarLeading: ToolbarItemPlacement { .automatic }
}
public extension ToolbarPlacement {
    static var navigationBar: ToolbarPlacement { .automatic }
}
public extension View {
    func fullScreenCover<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
    }
}
#endif

#if os(iOS)
@main
struct CompanionApp: App {
    @State private var store: CompanionStore
    @AppStorage(AppearanceSetting.storageKey) private var appearance: AppearanceSetting = .system

    init() {
        let store = CompanionEnvironment.makeStore()
        _store = State(initialValue: store)
        // Seed before the first frame so launch doesn't flash the default.
        let defaults = UserDefaults.standard
        FlotillaAccent.currentID = store.accentColor(
            own: defaults.string(forKey: FlotillaAccent.companionStorageKey) ?? FlotillaAccent.defaultID,
            followsMac: defaults.object(forKey: FlotillaAccent.companionFollowsMacStorageKey) as? Bool ?? true
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .modifier(CompanionAccent())
                .environment(store)
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}
#endif

/// Keeps `FlotillaAccent` on the paired Mac's accent while following it
/// (the default), otherwise on the one picked in this iPhone's settings.
private struct CompanionAccent: ViewModifier {
    @Environment(CompanionStore.self) private var store
    @AppStorage(FlotillaAccent.companionStorageKey) private var ownAccent: String = FlotillaAccent.defaultID
    @AppStorage(FlotillaAccent.companionFollowsMacStorageKey) private var followsMac = true

    func body(content: Content) -> some View {
        content
            .tint(FlotillaColors.accent)
            .onChange(of: store.accentColor(own: ownAccent, followsMac: followsMac), initial: true) { _, accent in
                FlotillaAccent.currentID = accent
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
        #endif
        return store
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

}

struct HapticsOnChange<Value: Equatable>: ViewModifier {
    let value: Value
    let feedback: SensoryFeedback

    func body(content: Content) -> some View {
        content.sensoryFeedback(feedback, trigger: value)
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
#if os(iOS)
    private var fleetActivity: FleetActivityController { .shared }

    /// Interactive app-switch gestures (home-indicator drag, Control Center,
    /// app-switcher peek) round-trip through `.background` in well under a
    /// second. Only tear down the Mac connection once we've stayed away long
    /// enough that this is a real backgrounding, not a passing gesture.
    private static let disconnectGrace: Duration = .seconds(2.5)

    private var fleetActivitySnapshot: FleetActivitySnapshot? {
        guard let macID = store.lastMacID, let mac = store.mac(macID) else { return nil }
        return FleetActivitySnapshot(mac: mac, sessions: store.sessions(on: macID),
                                     goesStale: scenePhase == .background && store.disconnectsWhenInactive)
    }
#else
    private static let disconnectGrace: Duration = .seconds(2.5)
#endif

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
            guard url.scheme == PairingPayload.scheme else { return }
            if url.host == "session",
               let id = UUID(uuidString: url.lastPathComponent),
               let macID = store.mac(forSession: id)?.id {
                store.path = [.fleet(macID), .session(id)]
            } else if url.host == "fleet" {
                let macID = String(url.path.dropFirst())
                if store.mac(macID) != nil { store.path = [.fleet(macID)] }
            } else if store.supportsPairing {
                store.incomingPairingLink = url.absoluteString
            }
        }
        .task { CompanionAttentionNotifications.shared.configure(store: store) }
#if os(iOS)
        .task(id: fleetActivitySnapshot) { await fleetActivity.sync(fleetActivitySnapshot) }
#endif
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
