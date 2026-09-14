#if DEBUG
import SwiftUI
import CompanionKit

/// Toolbar menu that starts a scripted scenario on the simulated data.
struct ScenarioMenu: View {
    @Environment(CompanionStore.self) private var store

    var body: some View {
        if store.supportsScenarios {
            Menu {
                ForEach(Scenario.allCases) { scenario in
                    Button(scenario.title) { store.run(scenario) }
                }
            } label: {
                Label("Scenarios", systemImage: "ladybug")
            }
        }
    }
}
#endif
