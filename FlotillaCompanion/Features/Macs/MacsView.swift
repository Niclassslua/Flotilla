import SwiftUI
import DesignSystem

/// Root: one row per paired Mac. No per-session preview here — that would
/// drift into a merged multi-Mac fleet.
struct MacsView: View {
    @Environment(CompanionStore.self) private var store
    @State private var isShowingSettings = false

    var body: some View {
        List {
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
        .scrollContentBackground(.hidden)
        .background(FlotillaColors.canvas)
        .navigationTitle("Macs")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Companion Settings", systemImage: "gearshape") { isShowingSettings = true }
            }
            #if DEBUG
            ToolbarItem(placement: .topBarLeading) { ScenarioMenu() }
            #endif
        }
        .sheet(isPresented: $isShowingSettings) {
            CompanionSettingsView()
        }
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
                        .fill(mac.isReachable ? FlotillaColors.statusWorking : FlotillaColors.statusIdle)
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

    private var summaryText: Text {
        guard mac.isReachable else {
            return Text("Unreachable · last seen \(mac.lastSeen.formatted(date: .omitted, time: .shortened))")
                .foregroundStyle(FlotillaColors.textTertiary)
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
