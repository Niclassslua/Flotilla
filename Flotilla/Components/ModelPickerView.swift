import SwiftUI
import SessionKit
import AgentKit
import SettingsKit
import DesignSystem

/// A compact, chip-based control for choosing the session's model.
///
/// The chip displays the human-facing display name of the selected model
/// (falling back to its raw slug) or "Default" when unset. Clicking opens a
/// popover listing real model names and — where published by the provider (e.g.
/// Codex) — per-model descriptions, plus "Default" and "Custom…" entries.
///
/// For Antigravity, models are grouped by base name (e.g. "Gemini 3.7 Flash");
/// selecting a group resolves through `group.resolvedSlug(for:)` against the
/// current reasoning effort rather than writing a raw base slug.
struct ModelPickerView: View {
    let agent: AgentKind
    let openCodeSubscription: OpenCodeSubscription
    @Binding var model: String
    var effort: AgentEffort? = nil
    var accessibilityIdentifier: String? = nil

    @State private var profiles: [AgentModelProfile] = []
    @State private var antigravityGroups: [AntigravityModelGroup] = []
    @State private var isPresented = false
    @State private var isHovering = false
    @State private var hoveredID: String?
    @State private var isCustomActive = false
    @State private var customText = ""
    @State private var isLoading = true
    @State private var lastSeenAgent: AgentKind?

    init(
        agent: AgentKind,
        openCodeSubscription: OpenCodeSubscription = .none,
        model: Binding<String>,
        effort: AgentEffort? = nil,
        accessibilityIdentifier: String? = nil
    ) {
        self.agent = agent
        self.openCodeSubscription = openCodeSubscription
        self._model = model
        self.effort = effort
        self.accessibilityIdentifier = accessibilityIdentifier
        if agent == .antigravity {
            self._antigravityGroups = State(initialValue: ModelCatalog.staticAntigravityGroups())
            self._profiles = State(initialValue: [])
        } else {
            self._profiles = State(initialValue: ModelCatalog.staticFallbackProfiles(for: agent, openCodeSubscription: openCodeSubscription))
            self._antigravityGroups = State(initialValue: [])
        }
    }

    private var isDefault: Bool {
        model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var currentDisplayName: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Default" }
        if agent == .antigravity {
            if let group = antigravityGroups.first(where: { isGroupSelected($0) }) {
                return group.displayName
            }
            return trimmed
        } else {
            if let profile = profiles.first(where: { $0.slug == trimmed }) {
                return profile.displayName ?? profile.slug
            }
            return trimmed
        }
    }

    var body: some View {
        chip
            .help("Model: \(currentDisplayName)")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Model: \(currentDisplayName)")
            .accessibilityValue(currentDisplayName)
            .accessibilityIdentifier(accessibilityIdentifier ?? "ModelPicker")
            .task(id: CatalogKey(agent: agent, openCodeSubscription: openCodeSubscription)) {
                if lastSeenAgent != nil, lastSeenAgent != agent {
                    model = ""
                    customText = ""
                    isCustomActive = false
                }
                lastSeenAgent = agent
                isLoading = true
                if agent == .antigravity {
                    antigravityGroups = ModelCatalog.staticAntigravityGroups()
                    let live = await ModelCatalogCache.shared.antigravityGroups()
                    guard !Task.isCancelled else { return }
                    if !live.isEmpty { antigravityGroups = live }
                } else {
                    profiles = ModelCatalog.staticFallbackProfiles(for: agent, openCodeSubscription: openCodeSubscription)
                    let live = await ModelCatalogCache.shared.profiles(for: agent, openCodeSubscription: openCodeSubscription)
                    guard !Task.isCancelled else { return }
                    if !live.isEmpty { profiles = live }
                }
                isLoading = false
                syncCustomText()
            }
    }

    private var chip: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(FlotillaColors.textTertiary)

                Text(currentDisplayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isDefault ? FlotillaColors.textSecondary : FlotillaColors.textPrimary)
                    .lineLimit(1)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                isHovering ? FlotillaColors.surfaceElevated : FlotillaColors.surfaceElevated.opacity(0.7),
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(
                    isHovering ? FlotillaColors.accent.opacity(0.6) : FlotillaColors.separator,
                    lineWidth: 0.5
                )
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Model")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .textCase(.uppercase)
                Spacer(minLength: 0)
                Text(agent.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)

            card(
                title: "Default",
                subtitle: "\(agent.displayName) default model",
                isSelected: isDefault,
                id: "__default__"
            ) {
                isCustomActive = false
                model = ""
                isPresented = false
            }

            Divider()
                .padding(.horizontal, 10)
                .padding(.vertical, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if agent == .antigravity {
                        ForEach(antigravityGroups) { group in
                            let isSelected = isGroupSelected(group)
                            card(
                                title: group.displayName,
                                subtitle: nil,
                                isSelected: isSelected,
                                id: group.id
                            ) {
                                isCustomActive = false
                                selectAntigravityGroup(group)
                                isPresented = false
                            }
                        }
                    } else {
                        ForEach(profiles) { profile in
                            let isSelected = model == profile.slug
                            card(
                                title: profile.displayName ?? profile.slug,
                                subtitle: profile.description,
                                isSelected: isSelected,
                                id: profile.slug
                            ) {
                                isCustomActive = false
                                model = profile.slug
                                isPresented = false
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 260)

            Divider()
                .padding(.horizontal, 10)
                .padding(.vertical, 4)

            customCard
        }
        .padding(.bottom, 8)
        .frame(width: 300)
    }

    private func selectAntigravityGroup(_ group: AntigravityModelGroup) {
        let eff = effort ?? currentAntigravityEffort()
        if let resolved = group.resolvedSlug(for: eff) {
            model = resolved
        } else if let sole = group.soleSlug {
            model = sole
        } else {
            model = group.baseSlug
        }
    }

    private func isGroupSelected(_ group: AntigravityModelGroup) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let sole = group.soleSlug, sole == trimmed { return true }
        return group.variants.values.contains(trimmed) || group.baseSlug == trimmed
    }

    private func currentAntigravityEffort() -> AgentEffort? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for group in antigravityGroups {
            for (eff, slug) in group.variants where slug == trimmed {
                return eff
            }
        }
        return nil
    }

    private var isCustomSelected: Bool {
        if isCustomActive { return true }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if agent == .antigravity {
            return !antigravityGroups.contains(where: { isGroupSelected($0) })
        } else {
            return !profiles.contains(where: { $0.slug == trimmed })
        }
    }

    private var customCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isCustomActive = true
                if customText.isEmpty && !model.isEmpty && isCustomSelected {
                    customText = model
                }
            } label: {
                HStack {
                    Text("Custom…")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FlotillaColors.textPrimary)
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(FlotillaColors.accent)
                        .opacity(isCustomSelected ? 1 : 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                        .fill(hoveredID == "__custom__" ? FlotillaColors.accent.opacity(0.12) : .clear)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .onHover { inside in
                if inside { hoveredID = "__custom__" } else if hoveredID == "__custom__" { hoveredID = nil }
            }

            if isCustomActive || isCustomSelected {
                TextField("Model name or slug", text: $customText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .autocorrectionDisabled()
                    .textContentType(nil)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                    .onChange(of: customText) { _, newValue in
                        model = newValue
                    }
                    .onSubmit {
                        isPresented = false
                    }
            }
        }
    }

    private func card(
        title: String,
        subtitle: String?,
        isSelected: Bool,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FlotillaColors.textPrimary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(FlotillaColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(FlotillaColors.accent)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                    .fill(hoveredID == id ? FlotillaColors.accent.opacity(0.12) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { inside in
            if inside { hoveredID = id } else if hoveredID == id { hoveredID = nil }
        }
        .accessibilityLabel(subtitle != nil && !subtitle!.isEmpty ? "\(title). \(subtitle!)" : title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func syncCustomText() {
        if isCustomSelected {
            customText = model
        }
    }

    private struct CatalogKey: Equatable {
        let agent: AgentKind
        let openCodeSubscription: OpenCodeSubscription
    }
}
