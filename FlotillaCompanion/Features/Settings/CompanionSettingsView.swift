import SwiftUI
import DesignSystem
import CompanionKit

/// Settings for this iPhone only — never Flotilla's own settings.
struct CompanionSettingsView: View {
    @Environment(CompanionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppearanceSetting.storageKey) private var appearance: AppearanceSetting = .system
    @AppStorage(FlotillaAccent.companionStorageKey) private var accentColor: String = FlotillaAccent.defaultID
    @State private var isConfirmingClearAll = false

    var body: some View {
        @Bindable var store = store
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

                Section {
                    AccentColorPicker(
                        accentColor: $accentColor,
                        customStorageKey: "companion.appearance.custom-accent"
                    )
                    .listRowBackground(FlotillaColors.surface)
                } header: {
                    Text("Accent Color")
                }

                Section {
                    Toggle("Agent is waiting for input", isOn: $store.notificationPreferences.waitingForInputEnabled)
                        .tint(.green)
                        .listRowBackground(FlotillaColors.surface)
                    Toggle("Ready for review", isOn: $store.notificationPreferences.readyForReviewEnabled)
                        .tint(.green)
                        .listRowBackground(FlotillaColors.surface)
                    Toggle("Session crashed", isOn: $store.notificationPreferences.crashedEnabled)
                        .tint(.green)
                        .listRowBackground(FlotillaColors.surface)
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Choose which attention events raise a notification on this iPhone. You're never notified while the app is open.")
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
                    Section {
                        Button("Clear Cached Transcripts for All Macs", role: .destructive) {
                            isConfirmingClearAll = true
                        }
                        .disabled(store.macs.isEmpty)
                    } footer: {
                        Text("Removes transcripts stored on this iPhone. Paired Macs, fleet summaries, and unsent drafts stay available. Drafts are discarded separately.")
                    }
                }

                Section {
                    LabeledContent("Handy Dictation") {
                        if store.isAnyMacSpeechAvailable {
                            Label("Available", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(FlotillaColors.statusWorking)
                        } else {
                            Text("Unavailable")
                                .foregroundStyle(FlotillaColors.textSecondary)
                        }
                    }
                    .listRowBackground(FlotillaColors.surface)
                } header: {
                    Text("Speech to Text (Handy)")
                } footer: {
                    Text("When connected to a Mac running Handy, you can dictate prompt messages directly into your sessions. Audio streams securely over your encrypted companion link and is transcribed locally on Apple Silicon by Handy. Audio is never persisted or sent to any cloud service.")
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
        .confirmationDialog("Clear cached transcripts for all Macs?", isPresented: $isConfirmingClearAll, titleVisibility: .visible) {
            Button("Clear Cached Transcripts", role: .destructive) { store.clearAllCachedTranscripts() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Transcripts stored on this iPhone will be removed. Paired Macs, fleet summaries, and unsent drafts will remain.")
        }
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
    @State private var isConfirmingClear = false

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

                Section {
                    LabeledContent("Status") {
                        if store.isSpeechAvailable(for: macID) {
                            Label("Connected & Ready", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(FlotillaColors.statusWorking)
                        } else {
                            Label("Unavailable", systemImage: "xmark.circle.fill")
                                .foregroundStyle(FlotillaColors.danger)
                        }
                    }
                    .listRowBackground(FlotillaColors.surface)
                } header: {
                    Text("Speech to Text (Handy)")
                } footer: {
                    Text("Transcribes dictation locally on Apple Silicon using Handy on this Mac. If unavailable, ensure Handy is running on this Mac with a speech model downloaded.")
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
                Button("Clear Cached Transcripts", role: .destructive) { isConfirmingClear = true }
            } footer: {
                Text("Removes this Mac's transcripts from this iPhone. Its fleet summary and unsent drafts remain.")
            }

            Section {
                Button("Remove Mac", role: .destructive) { isConfirmingRemove = true }
            } footer: {
                Text("To stop this Mac accepting the iPhone as well, remove the iPhone in Flotilla ▸ Settings ▸ iPhone Companion.")
            }
        }
        .navigationTitle(mac?.name ?? "Mac")
        .confirmationDialog("Clear cached transcripts for \(mac?.name ?? "this Mac")?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Clear Cached Transcripts", role: .destructive) { store.clearCachedTranscripts(on: macID) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Transcripts stored on this iPhone will be removed. The paired Mac, fleet summary, and unsent drafts will remain.")
        }
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
