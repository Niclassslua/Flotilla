import SwiftUI
import DesignSystem
import CompanionKit

/// Root: one row per paired Mac. No per-session preview here — that would
/// drift into a merged multi-Mac fleet.
struct MacsView: View {
    @Environment(CompanionStore.self) private var store
    @State private var isShowingSettings = false
    @State private var isPairing = false

    var body: some View {
        List {
            if store.macs.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(store.macs) { mac in
                        NavigationLink(value: Route.fleet(mac.id)) {
                            MacRow(mac: mac, summary: FleetSummary(sessions: store.sessions(on: mac.id)))
                        }
                        .listRowBackground(FlotillaColors.surface)
                    }
                } footer: {
                    Text("Macs running Flotilla that this iPhone is paired with.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(FlotillaColors.canvas)
        .navigationTitle("Macs")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("iPhone Settings", systemImage: "gearshape") { isShowingSettings = true }
            }
            if store.supportsPairing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Pair a Mac", systemImage: "plus") { isPairing = true }
                        .accessibilityIdentifier("Macs.Pair")
                }
            }
            #if DEBUG
            ToolbarItem(placement: .topBarLeading) { ScenarioMenu() }
            #endif
        }
        .sheet(isPresented: $isShowingSettings) {
            CompanionSettingsView()
        }
        .sheet(isPresented: $isPairing) {
            PairMacView { macID in
                store.path = [.fleet(macID)]
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 48))
                .foregroundStyle(FlotillaColors.textTertiary)
            Text("No Macs Yet")
                .font(.title2.weight(.semibold))
            Text("Pair this iPhone with Flotilla on your Mac to watch sessions, answer agents, and send prompts from anywhere.")
                .font(.subheadline)
                .foregroundStyle(FlotillaColors.textSecondary)
                .multilineTextAlignment(.center)
            if store.supportsPairing {
                Button {
                    isPairing = true
                } label: {
                    Text("Pair a Mac").frame(maxWidth: 240)
                }
                .companionGlassButtonStyle(prominent: true)
                .tint(FlotillaColors.accent)
                .controlSize(.large)
                .accessibilityIdentifier("Macs.PairFirst")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

private struct MacRow: View {
    let mac: MacHost
    let summary: FleetSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title3)
                .foregroundStyle(FlotillaColors.textSecondary)
                .frame(width: 30)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(FlotillaColors.surface, lineWidth: 2))
                        .offset(x: 3, y: 3)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(mac.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(FlotillaColors.textPrimary)
                summaryText
                    .font(.subheadline)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var dotColor: Color {
        switch mac.connection {
        case .connected: FlotillaColors.statusWorking
        case .connecting: FlotillaColors.statusWaitingForInput
        case .unreachable: FlotillaColors.statusIdle
        case .needsRepairing: FlotillaColors.danger
        }
    }

    private var summaryText: Text {
        switch mac.connection {
        case .needsRepairing:
            return Text("Needs pairing again").foregroundStyle(FlotillaColors.danger)
        case .unreachable:
            return Text("Unreachable · last seen \(mac.lastSeen.formatted(date: .omitted, time: .shortened))")
                .foregroundStyle(FlotillaColors.textTertiary)
        case .connecting where summary.total == 0:
            return Text("Connecting…").foregroundStyle(FlotillaColors.textTertiary)
        case .connecting, .connected:
            break
        }
        let neutral = summary.workingText.map { Text($0).foregroundStyle(FlotillaColors.textSecondary) }
        let urgent = summary.needsYouText.map { Text($0).foregroundStyle(FlotillaColors.accent).fontWeight(.medium) }
        switch (neutral, urgent) {
        case let (neutral?, urgent?):
            return Text("\(neutral)\(Text(" · ").foregroundStyle(FlotillaColors.textTertiary))\(urgent)")
        case let (neutral?, nil):
            return neutral
        case let (nil, urgent?):
            return urgent
        case (nil, nil):
            return Text("")
        }
    }
}

#Preview {
    NavigationStack { MacsView() }
        .environment(CompanionStore(data: MockCompanionDataSource()))
        .preferredColorScheme(.dark)
}
