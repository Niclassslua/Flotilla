import SwiftUI
import SessionKit
import CompanionKit
import DesignSystem

/// iOS sheet for selecting a model from the companion catalog.
struct ModelPickerSheet: View {
    let agent: AgentKind
    let entry: AgentCatalog.Entry
    @Binding var model: String
    let effort: AgentEffort?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        selectDefault()
                    } label: {
                        modelRow(
                            title: "Default",
                            subtitle: "\(agent.displayName) default model",
                            isSelected: isDefault
                        )
                    }
                }

                Section("Available Models") {
                    if agent.bakesEffortIntoModelSlug {
                        ForEach(entry.antigravityGroups) { group in
                            Button {
                                selectAntigravityGroup(group)
                            } label: {
                                modelRow(
                                    title: group.displayName,
                                    subtitle: nil,
                                    isSelected: isAntigravityGroupSelected(group)
                                )
                            }
                        }
                    } else {
                        ForEach(entry.models) { option in
                            Button {
                                model = option.slug
                                dismiss()
                            } label: {
                                modelRow(
                                    title: option.displayName ?? option.slug,
                                    subtitle: option.description,
                                    isSelected: model == option.slug
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var isDefault: Bool {
        model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model == entry.defaultModel
    }

    private func selectDefault() {
        model = entry.defaultModel
        dismiss()
    }

    private func isAntigravityGroupSelected(_ group: AntigravityGroupOption) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let sole = group.soleSlug, sole == trimmed { return true }
        return group.variants.values.contains(trimmed) || group.baseSlug == trimmed
    }

    private func selectAntigravityGroup(_ group: AntigravityGroupOption) {
        let resolved = group.resolvedSlug(for: effort) ?? group.soleSlug ?? group.baseSlug
        model = resolved
        dismiss()
    }

    private func modelRow(title: String, subtitle: String?, isSelected: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(FlotillaColors.textPrimary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(FlotillaColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FlotillaColors.accent)
            }
        }
        .contentShape(Rectangle())
    }
}
