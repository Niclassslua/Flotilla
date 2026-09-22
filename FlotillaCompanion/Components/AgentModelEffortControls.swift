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

    @State private var isModelSheetPresented = false
    @State private var isEffortSheetPresented = false

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

            Button {
                isModelSheetPresented = true
            } label: {
                HStack {
                    Label {
                        Text("Model")
                            .foregroundStyle(FlotillaColors.textPrimary)
                    } icon: {
                        Image(systemName: "cpu")
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }
                    Spacer()
                    Text(selectedModelDisplayName)
                        .foregroundStyle(FlotillaColors.textSecondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $isModelSheetPresented) {
                ModelPickerSheet(
                    agent: agent,
                    entry: entry,
                    model: $model,
                    effort: effectiveEffort
                )
            }

            if supportsEffort {
                Button {
                    isEffortSheetPresented = true
                } label: {
                    HStack {
                        Label {
                            Text("Effort")
                                .foregroundStyle(FlotillaColors.textPrimary)
                        } icon: {
                            Image(systemName: "brain")
                                .foregroundStyle(FlotillaColors.textTertiary)
                        }
                        Spacer()
                        if let currentEffort = effectiveEffort {
                            HStack(spacing: 6) {
                                effortMeter(for: currentEffort)
                                Text(catalog.effortLabel(currentEffort, agent: agent))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(currentEffort.tint)
                            }
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $isEffortSheetPresented) {
                    EffortPickerSheet(
                        agent: agent,
                        entry: entry,
                        model: $model,
                        effort: $effort,
                        availableLevels: availableEffortLevels
                    )
                }
            }
        }
        .onAppear { clampToAgent() }
    }

    private var supportsEffort: Bool {
        guard agent.supportsEffortSelection else { return false }
        let entry = catalog.entry(for: agent)
        if agent.bakesEffortIntoModelSlug {
            if entry.antigravityGroups.isEmpty {
                return !entry.effortLevels.isEmpty
            }
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return true }
            if let group = entry.antigravityGroups.first(where: {
                $0.variants.values.contains(trimmed) || $0.soleSlug == trimmed || $0.baseSlug == trimmed
            }) {
                return !group.variants.isEmpty
            }
            return false
        }
        return !entry.effortLevels.isEmpty
    }

    private var availableEffortLevels: [AgentEffort] {
        let entry = catalog.entry(for: agent)
        if agent.bakesEffortIntoModelSlug {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if let group = entry.antigravityGroups.first(where: {
                $0.variants.values.contains(trimmed) || $0.soleSlug == trimmed || $0.baseSlug == trimmed
            }), !group.variants.isEmpty {
                return group.variants.keys.sorted { $0.rank < $1.rank }
            }
            return entry.effortLevels
        }
        return entry.effortLevels
    }

    private var effectiveEffort: AgentEffort? {
        let entry = catalog.entry(for: agent)
        if agent.bakesEffortIntoModelSlug {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if let group = entry.antigravityGroups.first(where: { $0.variants.values.contains(trimmed) }) {
                for (lvl, s) in group.variants where s == trimmed {
                    return lvl
                }
            }
            return effort ?? entry.defaultEffort
        }
        return effort ?? entry.defaultEffort
    }

    private var selectedModelDisplayName: String {
        let entry = catalog.entry(for: agent)
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if agent.bakesEffortIntoModelSlug {
            if let group = entry.antigravityGroups.first(where: {
                $0.variants.values.contains(trimmed) || $0.soleSlug == trimmed || $0.baseSlug == trimmed
            }) {
                return group.displayName
            }
            if let opt = entry.models.first(where: { $0.slug == trimmed }) {
                return opt.displayName ?? opt.slug
            }
            return trimmed.isEmpty ? "Default" : trimmed
        } else {
            if let opt = entry.models.first(where: { $0.slug == trimmed }) {
                return opt.displayName ?? opt.slug
            }
            return trimmed.isEmpty ? "Default" : trimmed
        }
    }

    private func effortMeter(for level: AgentEffort) -> some View {
        let levels = availableEffortLevels
        let index = levels.firstIndex(of: level) ?? 0
        let total = max(levels.count, 1)
        return HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<total, id: \.self) { pos in
                Capsule()
                    .fill(pos <= index ? level.tint : FlotillaColors.separatorStrong.opacity(0.5))
                    .frame(
                        width: 2.5,
                        height: 12 * (0.4 + 0.6 * CGFloat(pos + 1) / CGFloat(total))
                    )
            }
        }
        .frame(height: 12, alignment: .bottom)
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
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if agent.bakesEffortIntoModelSlug {
            let isKnown = entry.antigravityGroups.contains { group in
                group.variants.values.contains(trimmed) || group.soleSlug == trimmed || group.baseSlug == trimmed
            } || entry.models.contains { $0.slug == trimmed }
            if !isKnown && !trimmed.isEmpty {
                model = entry.defaultModel
            }
            if let current = effort, !entry.effortLevels.contains(current) {
                effort = entry.defaultEffort
            }
            if effort == nil && agent.supportsEffortSelection {
                effort = entry.defaultEffort
            }
        } else {
            if !entry.models.contains(where: { $0.slug == trimmed }) && !trimmed.isEmpty {
                model = entry.defaultModel
            }
            if let current = effort, !entry.effortLevels.contains(current) {
                effort = entry.defaultEffort
            }
            if effort == nil, agent.supportsEffortSelection {
                effort = entry.defaultEffort
            }
        }
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
