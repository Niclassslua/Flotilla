import SwiftUI
import SessionKit
import CompanionKit
import DesignSystem

/// iOS sheet for choosing reasoning effort from the companion catalog.
struct EffortPickerSheet: View {
    let agent: AgentKind
    let entry: AgentCatalog.Entry
    @Binding var model: String
    @Binding var effort: AgentEffort?
    let availableLevels: [AgentEffort]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(availableLevels) { level in
                        Button {
                            select(level)
                        } label: {
                            effortRow(for: level)
                        }
                    }
                } footer: {
                    Text("Controls how much reasoning effort the coding agent applies before responding.")
                }
            }
            .navigationTitle("Reasoning Effort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func select(_ level: AgentEffort) {
        effort = level
        if agent == .antigravity {
            if let group = entry.antigravityGroups.first(where: {
                $0.variants.values.contains(model) || $0.baseSlug == model
            }) {
                if let resolved = group.resolvedSlug(for: level) {
                    model = resolved
                }
            } else if model.isEmpty, let defaultGroup = entry.antigravityGroups.first {
                if let resolved = defaultGroup.resolvedSlug(for: level) {
                    model = resolved
                }
            }
        }
        dismiss()
    }

    private func effortRow(for level: AgentEffort) -> some View {
        let isSelected = effort == level
        let label = entry.effortLabels[level] ?? level.displayName
        return HStack(spacing: 12) {
            meter(for: level, height: 18, width: 3.5)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.body.weight(.medium))
                        .foregroundStyle(FlotillaColors.textPrimary)
                    if entry.defaultEffort == level {
                        Text("Default")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(level.tint)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(level.tint.opacity(0.14), in: Capsule())
                    }
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(level.tint)
            }
        }
        .contentShape(Rectangle())
    }

    private func meter(for level: AgentEffort, height: CGFloat, width: CGFloat) -> some View {
        let index = availableLevels.firstIndex(of: level) ?? 0
        let total = max(availableLevels.count, 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<total, id: \.self) { pos in
                Capsule()
                    .fill(pos <= index ? level.tint : FlotillaColors.separatorStrong.opacity(0.5))
                    .frame(
                        width: width,
                        height: height * (0.4 + 0.6 * CGFloat(pos + 1) / CGFloat(total))
                    )
            }
        }
        .frame(height: height, alignment: .bottom)
    }
}
