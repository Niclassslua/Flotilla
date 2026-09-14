import SwiftUI
import DesignSystem
import CompanionKit

/// Settings for this iPhone only — never Flotilla's own settings.
struct CompanionSettingsView: View {
    @Environment(CompanionStore.self) private var store
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

                if store.supportsPairing {
                    Section("Paired Macs") {
                        if store.macs.isEmpty {
                            Text("No Macs paired.").foregroundStyle(FlotillaColors.textSecondary)
                        }
                        ForEach(store.macs) { mac in
                            NavigationLink {
                                MacConnectionDetailView(macID: mac.id)
                            } label: {
                                LabeledContent(mac.name, value: connectionLabel(mac.connection))
                            }
                            .listRowBackground(FlotillaColors.surface)
                        }
                    }
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

    private func connectionLabel(_ state: MacConnectionState) -> String {
        switch state {
        case .connected(let path, _): "Connected · \(path.displayName)"
        case .connecting: "Connecting…"
        case .unreachable: "Unreachable"
        case .needsRepairing: "Needs pairing"
        }
    }
}

/// How the phone reaches one Mac, what the last attempt found, and removal.
struct MacConnectionDetailView: View {
    let macID: MacHost.ID
    @Environment(CompanionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingRemove = false

    var body: some View {
        let mac = store.mac(macID)
        let details = (store.data as? RemoteCompanionDataSource)?.diagnostics(for: macID)
        Form {
            if let mac {
                Section("Status") {
                    switch mac.connection {
                    case .connected(let path, let address):
                        LabeledContent("Connected", value: "\(path.displayName) · \(address)")
                    case .connecting:
                        LabeledContent("Status", value: "Connecting…")
                    case .unreachable:
                        LabeledContent("Status", value: "Unreachable")
                        LabeledContent("Last seen", value: mac.lastSeen.formatted(date: .abbreviated, time: .shortened))
                    case .needsRepairing(let reason):
                        Text(reason.message).foregroundStyle(FlotillaColors.danger)
                    }
                    Button("Reconnect Now") { store.reconnect(macID) }
                        .disabled(mac.isReachable)
                }
            }

            if let details {
                Section("Addresses") {
                    ForEach(details.record.candidates, id: \.self) { candidate in
                        LabeledContent(candidate.kind.path.displayName, value: candidate.host)
                    }
                }
                if let diagnosis = details.diagnosis, mac?.isReachable == false {
                    Section("Last attempt") {
                        Text(diagnosis.title).font(.headline)
                        ForEach(diagnosis.paths) { report in
                            ForEach(diagnosis.advice(for: report), id: \.self) { line in
                                Label(line, systemImage: report.path == .lan ? "wifi" : "point.3.filled.connected.trianglepath.dotted")
                                    .font(.footnote)
                            }
                        }
                    }
                }
            }

            Section {
                Button("Remove Mac", role: .destructive) { isConfirmingRemove = true }
            } footer: {
                Text("To stop this Mac accepting the iPhone as well, remove the iPhone in Flotilla ▸ Settings ▸ iPhone Companion.")
            }
        }
        .navigationTitle(mac?.name ?? "Mac")
        .confirmationDialog("Remove \(mac?.name ?? "this Mac")?", isPresented: $isConfirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                store.removeMac(macID)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its cached sessions are deleted from this iPhone. You can pair again at any time.")
        }
    }
}
