import SwiftUI
import SessionKit
import AgentKit
import SettingsKit

/// A dropdown of the current `agent`'s available models — fetched live from
/// the installed CLI (`AgentKit.ModelCatalogCache`), falling back to a small
/// static shortlist if that fails — plus a "Custom…" option that reveals a
/// text field. `model` is the resolved value passed straight to
/// `AppStore.createSession` — empty means "agent's own default".
///
/// Lives in its own file because both `CommandBarDesign` (the New Session
/// window) and `LaunchpadDesign` (the home composer) embed it.
struct ModelPickerView: View {
    let agent: AgentKind
    let openCodeSubscription: OpenCodeSubscription
    @Binding var model: String

    @State private var selection = ""
    @State private var customText = ""
    @State private var availableModels: [String] = []
    @State private var isLoading = true

    private let customTag = "__custom__"

    var body: some View {
        HStack(spacing: 8) {
            Picker("Model", selection: $selection) {
                Text("Default").tag("")
                ForEach(availableModels, id: \.self) { preset in
                    Text(preset).tag(preset)
                }
                Text("Custom…").tag(customTag)
            }
            .labelsHidden()
            .onChange(of: selection) { _, newValue in
                model = newValue == customTag ? customText : newValue
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .help("Fetching available models from the CLI…")
            }

            if selection == customTag {
                TextField("Model name", text: $customText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: customText) { _, newValue in
                        model = newValue
                    }
            }
        }
        // `.task(id:)` re-fetches (cancelling any in-flight fetch) whenever
        // `agent` changes. A model chosen for one agent is almost never
        // valid for another, so switching resets back to "Default" rather
        // than silently carrying a stale value.
        .task(id: agent) {
            selection = ""
            customText = ""
            model = ""
            isLoading = true
            availableModels = await ModelCatalogCache.shared.models(for: agent, openCodeSubscription: openCodeSubscription)
            isLoading = false
            syncSelection(presets: availableModels)
        }
    }

    private func syncSelection(presets: [String]) {
        if model.isEmpty {
            selection = ""
        } else if presets.contains(model) {
            selection = model
        } else {
            selection = customTag
            customText = model
        }
    }
}
