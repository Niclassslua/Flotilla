import SwiftUI
import SessionKit
import AgentKit
import DesignSystem

/// A compact, self-labeled control for choosing reasoning effort.
///
/// The chip shows the current level as a rank meter plus its name; clicking it
/// opens a popover where each level states what it costs and what it buys, so
/// "what does X-High actually do?" is answered in the UI instead of a tooltip.
///
/// The levels offered are never assumed: they come from `AgentEffortCatalog`
/// for the *current agent and model*, since Claude Code and Codex accept
/// different sets (and different names for them), Codex narrows its set per
/// model, and OpenCode has no effort knob at all — in which case this renders
/// nothing. A level that the new agent/model doesn't accept is clamped to the
/// nearest one that it does.
struct EffortLevelPicker: View {
    let agent: AgentKind
    /// The resolved model slug; empty means "the agent's own default model",
    /// for which the agent-wide level set is offered.
    var model: String = ""
    @Binding var effort: AgentEffort
    var accessibilityIdentifier: String? = nil

    @State private var options: [AgentEffortOption]
    @State private var isPresented = false
    @State private var isHovering = false
    @State private var hovered: AgentEffort?

    init(
        agent: AgentKind,
        model: String = "",
        effort: Binding<AgentEffort>,
        accessibilityIdentifier: String? = nil
    ) {
        self.agent = agent
        self.model = model
        _effort = effort
        self.accessibilityIdentifier = accessibilityIdentifier
        // Seeded synchronously from the offline catalog so the first frame
        // already shows a plausible set; the CLI query below refines it.
        _options = State(initialValue: AgentEffortCatalog.options(
            for: agent,
            model: model,
            profiles: ModelCatalog.staticFallbackProfiles(for: agent)
        ))
    }

    private var selected: AgentEffortOption? {
        options.first { $0.level == effort }
    }

    private var selectedLabel: String {
        selected?.label ?? AgentEffortCatalog.label(for: effort, agent: agent)
    }

    var body: some View {
        // Gated on the agent (not on `options`) so the control's presence
        // never depends on the CLI query having finished — and so the task
        // below always has a live view to attach to.
        if agent.supportsEffortSelection {
            chip
                .help("Reasoning effort: \(selectedLabel). \(selected?.summary ?? "")")
                .accessibilityElement(children: .contain)
                // The current level is folded into the label (rather than
                // relying solely on `.accessibilityValue`) because this
                // custom control's AX value isn't reliably surfaced to
                // assistive clients on macOS.
                .accessibilityLabel("Reasoning effort: \(selectedLabel)")
                .accessibilityValue(selectedLabel)
                .accessibilityHint("Choose how much reasoning the coding agent should use.")
                .accessibilityAdjustableAction(adjust)
                .accessibilityIdentifier(accessibilityIdentifier ?? "EffortLevelPicker")
                // Re-seed from the static table (the agent or model may have
                // changed since init), then refine with the live per-model
                // set. `.task(id:)` re-runs — cancelling any in-flight fetch —
                // whenever either half of the key changes.
                .task(id: CatalogKey(agent: agent, model: model)) {
                    apply(AgentEffortCatalog.options(
                        for: agent,
                        model: model,
                        profiles: ModelCatalog.staticFallbackProfiles(for: agent)
                    ))
                    let profiles = await ModelCatalogCache.shared.profiles(for: agent)
                    guard !Task.isCancelled else { return }
                    apply(AgentEffortCatalog.options(for: agent, model: model, profiles: profiles))
                }
        }
    }

    private func apply(_ newOptions: [AgentEffortOption]) {
        options = newOptions
        if let clamped = AgentEffortCatalog.clamp(effort, to: newOptions), clamped != effort {
            effort = clamped
        }
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        guard let index = options.firstIndex(where: { $0.level == effort }) else { return }
        let next = direction == .increment ? index + 1 : index - 1
        guard options.indices.contains(next) else { return }
        effort = options[next].level
    }

    private var chip: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                meter(for: effort, height: 12, width: 2.5)

                Text(selectedLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(effort.tint)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(effort.tint.opacity(isHovering ? 0.14 : 0.08), in: Capsule())
            .overlay {
                Capsule().strokeBorder(effort.tint.opacity(isHovering ? 0.7 : 0.35))
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.snappy(duration: 0.18), value: effort)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Reasoning Effort")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .textCase(.uppercase)
                Spacer(minLength: 0)
                Text(modelScopeLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)

            ForEach(options) { option in
                card(option)
            }

            if let hint = AgentEffortCatalog.invocationHint(for: effort, agent: agent) {
                Divider()
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                Text(hint)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }
        }
        .padding(.bottom, 8)
        .frame(width: 300)
    }

    /// Names what the offered set is scoped to, since it differs per model.
    private var modelScopeLabel: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(agent.displayName) default model" : trimmed
    }

    private func card(_ option: AgentEffortOption) -> some View {
        let isSelected = option.level == effort
        return Button {
            withAnimation(.snappy(duration: 0.18)) { effort = option.level }
            isPresented = false
        } label: {
            HStack(alignment: .top, spacing: 10) {
                meter(for: option.level, height: 16, width: 3)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(option.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(FlotillaColors.textPrimary)
                        if option.isModelDefault {
                            Text("Model default")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(option.level.tint)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(option.level.tint.opacity(0.14), in: Capsule())
                        }
                    }
                    Text(option.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(FlotillaColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(option.level.tint)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                    .fill(hovered == option.level ? option.level.tint.opacity(0.12) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { inside in
            if inside { hovered = option.level } else if hovered == option.level { hovered = nil }
        }
        .accessibilityLabel("\(option.label). \(option.summary)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Rank meter over the levels *this* model offers, so a six-level Codex
    /// model and a five-level Claude model both read as "how far up the range
    /// am I" rather than against some absolute scale.
    private func meter(for level: AgentEffort, height: CGFloat, width: CGFloat) -> some View {
        let index = options.firstIndex { $0.level == level } ?? 0
        return HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(options.enumerated()), id: \.element.id) { position, option in
                Capsule()
                    .fill(position <= index ? level.tint : FlotillaColors.separatorStrong.opacity(0.5))
                    .frame(
                        width: width,
                        height: height * (0.4 + 0.6 * CGFloat(position + 1) / CGFloat(Swift.max(options.count, 1)))
                    )
            }
        }
        .frame(height: height, alignment: .bottom)
    }

    /// Identity for `.task(id:)` — refetch when either half changes.
    private struct CatalogKey: Equatable {
        let agent: AgentKind
        let model: String
    }
}

extension AgentEffort {
    /// Cool-to-hot ramp: slate → steel → cyan → amber → orange → red →
    /// magenta. Used as a foreground tint throughout, never as a fill behind
    /// text, so every step only has to read against the panel background.
    var tint: Color {
        switch self {
        case .minimal: Color(red: 0.42, green: 0.47, blue: 0.53)
        case .low: Color(red: 0.30, green: 0.55, blue: 0.68)
        case .medium: FlotillaColors.statusReady
        case .high: FlotillaColors.warning
        case .xhigh: FlotillaColors.accent
        case .max: FlotillaColors.danger
        case .ultra: Color(red: 0.80, green: 0.30, blue: 0.72)
        }
    }
}

#Preview("Effort level picker") {
    VStack(alignment: .leading, spacing: 12) {
        StatefulEffortPreview(agent: .claudeCode, model: "opus")
        StatefulEffortPreview(agent: .codexCLI, model: "gpt-5.6-sol")
        StatefulEffortPreview(agent: .codexCLI, model: "gpt-5.4")
        StatefulEffortPreview(agent: .openCode, model: "")
    }
    .padding(24)
}

private struct StatefulEffortPreview: View {
    let agent: AgentKind
    let model: String
    @State private var effort: AgentEffort = .medium

    var body: some View {
        HStack(spacing: 10) {
            Text("\(agent.displayName) · \(model.isEmpty ? "—" : model)")
                .font(.caption)
                .frame(width: 180, alignment: .leading)
            EffortLevelPicker(agent: agent, model: model, effort: $effort)
        }
    }
}
