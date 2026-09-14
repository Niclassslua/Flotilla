import SwiftUI
import DesignSystem

/// Settings for this iPhone only — never Flotilla's own settings.
struct CompanionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppearanceSetting.storageKey) private var appearance: AppearanceSetting = .system

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppearanceSetting.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(FlotillaColors.surface)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("These settings apply to this iPhone only. Flotilla's own settings stay on your Mac.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(FlotillaColors.canvas)
            .navigationTitle("iPhone Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    CompanionSettingsView()
}
