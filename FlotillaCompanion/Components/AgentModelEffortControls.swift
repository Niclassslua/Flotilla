import SwiftUI
import SessionKit
import DesignSystem
import CompanionKit

/// Agent, model, and effort pickers shared by create session and handoff.
/// Meant to sit inside a `Form`.
struct AgentModelEffortControls: View {
    @Binding var agent: AgentKind
    @Binding var model: String
    @Binding var effort: AgentEffort?
    let catalog: AgentCatalog
    var agents: [AgentKind] = AgentKind.allCases

    var body: some View {
        Section("Agent") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(agents) { kind in
                        AgentChip(agent: kind, isSelected: kind == agent) {
                            select(kind)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))

            let entry = catalog.entry(for: agent)
            Picker("Model", selection: $model) {
                ForEach(entry.models, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)

            if agent.supportsEffortSelection, !entry.effortLevels.isEmpty {
                Picker("Effort", selection: $effort) {
                    ForEach(entry.effortLevels) { level in
                        Text(catalog.effortLabel(level, agent: agent)).tag(Optional(level))
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .onAppear { clampToAgent() }
    }

    private func select(_ kind: AgentKind) {
        guard kind != agent else { return }
        agent = kind
        let entry = catalog.entry(for: kind)
        model = entry.defaultModel
        effort = entry.defaultEffort
    }

    /// A remembered model or effort the agent no longer offers falls back to
    /// its default rather than showing an empty picker.
    private func clampToAgent() {
        let entry = catalog.entry(for: agent)
        if !entry.models.contains(model) { model = entry.defaultModel }
        if let current = effort, !entry.effortLevels.contains(current) { effort = entry.defaultEffort }
        if effort == nil, agent.supportsEffortSelection { effort = entry.defaultEffort }
    }
}

private struct AgentChip: View {
    let agent: AgentKind
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ProviderLogo(agent: agent)
                    .frame(width: 26, height: 26)
                Text(agent.displayName)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            }
            .frame(width: 84, height: 66)
            .foregroundStyle(isSelected ? FlotillaColors.textPrimary : FlotillaColors.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                    .fill(isSelected ? FlotillaColors.surfaceElevated : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                    .strokeBorder(isSelected ? FlotillaColors.accent : FlotillaColors.separator, lineWidth: isSelected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(agent.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
