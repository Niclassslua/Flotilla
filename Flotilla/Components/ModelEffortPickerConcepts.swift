import SwiftUI
import DesignSystem

/// A visual decision board for four ways to combine model and reasoning effort
/// into a single control. Kept separate from the production picker until a
/// direction is selected.
///
/// Each concept uses one trigger and one popover: model is the primary choice;
/// reasoning is visible at a glance and adjustable without a second control.
struct ModelEffortPickerConceptGallery: View {
    private enum Concept: String, CaseIterable, Identifiable {
        case spectrum, dossier, horizon, signal

        var id: String { rawValue }
    }

    private struct Model: Identifiable {
        let id: String
        let name: String
        let detail: String
    }

    private struct Effort: Identifiable {
        let id: String
        let name: String
        let summary: String
        let tint: Color
        let rank: Int
    }

    private let models = [
        Model(id: "gpt-5.4", name: "GPT-5.4", detail: "Balanced coding agent"),
        Model(id: "opus", name: "Claude Opus 4.6", detail: "Deepest planning and review"),
        Model(id: "flash", name: "Gemini 3.7 Flash", detail: "Fast iterations")
    ]

    private let efforts = [
        Effort(id: "low", name: "Low", summary: "Fast answers, lighter planning", tint: Color(red: 0.30, green: 0.55, blue: 0.68), rank: 1),
        Effort(id: "medium", name: "Medium", summary: "A balanced amount of reasoning", tint: FlotillaColors.statusReady, rank: 2),
        Effort(id: "high", name: "High", summary: "More analysis before acting", tint: FlotillaColors.warning, rank: 3),
        Effort(id: "X-High", name: "X-High", summary: "Maximum care for complex work", tint: FlotillaColors.accent, rank: 4)
    ]

    @State private var selectedModelID = "gpt-5.4"
    @State private var selectedEffortID = "X-High"
    @State private var openConcept: Concept?

    private var selectedModel: Model { models.first { $0.id == selectedModelID } ?? models[0] }
    private var selectedEffort: Effort { efforts.first { $0.id == selectedEffortID } ?? efforts[0] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FlotillaSpacing.xLarge) {
                header
                VStack(spacing: FlotillaSpacing.medium) {
                    conceptCard(.spectrum, number: "01", title: "Inline spectrum", note: "The most compact option. A continuous control reads as one choice with two dimensions.") {
                        spectrumTrigger
                    }
                    conceptCard(.dossier, number: "02", title: "Two-line dossier", note: "More legible at a glance. Treats the current configuration like a small session specification.") {
                        dossierTrigger
                    }
                    conceptCard(.horizon, number: "03", title: "Split horizon", note: "A clean left/right hierarchy. Model has the stable surface; effort is a live, colored state.") {
                        horizonTrigger
                    }
                    conceptCard(.signal, number: "04", title: "Signal token", note: "The most expressive option. A compact effort signal becomes the memorable anchor without adding another chip.") {
                        signalTrigger
                    }
                }
            }
            .padding(FlotillaSpacing.xxLarge)
        }
        .frame(width: 700, height: 760)
        .background(FlotillaColors.surface)
        .popover(item: $openConcept, arrowEdge: .bottom) { concept in
            unifiedMenu(for: concept)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.xSmall) {
            Text("ONE CONTROL, TWO DECISIONS")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(FlotillaColors.accent)
                .tracking(1.4)
            Text("Model + reasoning picker")
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .foregroundStyle(FlotillaColors.textPrimary)
            Text("All four concepts open the same combined picker. The difference is how much context the resting control carries.")
                .font(.system(size: 13))
                .foregroundStyle(FlotillaColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func conceptCard<Content: View>(
        _ concept: Concept,
        number: String,
        title: String,
        note: String,
        @ViewBuilder control: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
            HStack(alignment: .firstTextBaseline) {
                Text(number)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(FlotillaColors.accent)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FlotillaColors.textPrimary)
                Spacer(minLength: 0)
                Text("ONE POPOVER")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .tracking(0.8)
            }
            HStack(spacing: FlotillaSpacing.large) {
                control()
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(FlotillaSpacing.large)
        .background(FlotillaColors.surfaceElevated.opacity(0.74), in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
        }
    }

    private var spectrumTrigger: some View {
        conceptButton(.spectrum) {
            HStack(spacing: 9) {
                Image(systemName: "cpu")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlotillaColors.textTertiary)
                Text(selectedModel.name)
                    .font(.system(size: 12, weight: .semibold))
                Rectangle().fill(FlotillaColors.separator).frame(width: 1, height: 16)
                rankMeter
                Text(selectedEffort.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selectedEffort.tint)
                chevron
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(FlotillaColors.surfaceElevated, in: Capsule())
            .overlay { Capsule().strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline) }
        }
    }

    private var dossierTrigger: some View {
        conceptButton(.dossier) {
            HStack(spacing: 11) {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(FlotillaColors.accent)
                    .frame(width: 26, height: 26)
                    .background(FlotillaColors.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("MODEL · REASONING")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .tracking(0.7)
                    Text("\(selectedModel.name)  /  \(selectedEffort.name)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FlotillaColors.textPrimary)
                }
                chevron
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(FlotillaColors.surfaceElevated, in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous).strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline) }
        }
    }

    private var horizonTrigger: some View {
        conceptButton(.horizon) {
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "cpu")
                        .font(.system(size: 11, weight: .medium))
                    Text(selectedModel.name)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(FlotillaColors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                Rectangle().fill(FlotillaColors.separator).frame(width: 1, height: 22)
                HStack(spacing: 6) {
                    rankMeter
                    Text(selectedEffort.name)
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(selectedEffort.tint)
                .padding(.horizontal, 10)
                chevron
                    .padding(.trailing, 9)
            }
            .background(FlotillaColors.surfaceElevated, in: Capsule())
            .overlay { Capsule().strokeBorder(selectedEffort.tint.opacity(0.38), lineWidth: FlotillaBorderWidth.hairline) }
        }
    }

    private var signalTrigger: some View {
        conceptButton(.signal) {
            HStack(spacing: 9) {
                ZStack {
                    Circle().fill(selectedEffort.tint.opacity(0.16))
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(selectedEffort.tint)
                }
                .frame(width: 29, height: 29)
                VStack(alignment: .leading, spacing: 1) {
                    Text(selectedModel.name)
                        .font(.system(size: 12, weight: .semibold))
                    Text("Reasoning: \(selectedEffort.name)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(selectedEffort.tint)
                }
                chevron
            }
            .padding(6)
            .padding(.trailing, 4)
            .background(FlotillaColors.surfaceElevated, in: Capsule())
            .overlay { Capsule().strokeBorder(FlotillaColors.separatorStrong, lineWidth: FlotillaBorderWidth.hairline) }
        }
    }

    private func conceptButton<Label: View>(_ concept: Concept, @ViewBuilder label: () -> Label) -> some View {
        Button { openConcept = concept } label: { label() }
            .buttonStyle(.plain)
            .help("Choose model and reasoning effort")
            .accessibilityLabel("Model: \(selectedModel.name). Reasoning effort: \(selectedEffort.name)")
    }

    private var chevron: some View {
        Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(FlotillaColors.textTertiary)
            .accessibilityHidden(true)
    }

    private var rankMeter: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(1...4, id: \.self) { rank in
                Capsule()
                    .fill(rank <= selectedEffort.rank ? selectedEffort.tint : FlotillaColors.separatorStrong.opacity(0.5))
                    .frame(width: 2.5, height: CGFloat(5 + rank * 2))
            }
        }
        .frame(height: 14, alignment: .bottom)
        .accessibilityHidden(true)
    }

    private func unifiedMenu(for concept: Concept) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MODEL + REASONING")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .tracking(1)
                    Text(menuTitle(for: concept))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(FlotillaColors.textPrimary)
                }
                Spacer(minLength: 0)
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(FlotillaColors.accent)
            }
            .padding(.horizontal, FlotillaSpacing.medium)
            .padding(.top, FlotillaSpacing.medium)
            .padding(.bottom, FlotillaSpacing.small)

            menuSection("MODEL") {
                ForEach(models) { model in
                    selectionRow(title: model.name, detail: model.detail, selected: selectedModelID == model.id) {
                        selectedModelID = model.id
                    }
                }
            }

            Divider().padding(.vertical, FlotillaSpacing.small)

            menuSection("REASONING EFFORT") {
                ForEach(efforts) { effort in
                    selectionRow(title: effort.name, detail: effort.summary, selected: selectedEffortID == effort.id, tint: effort.tint, leading: AnyView(effortMeter(for: effort))) {
                        selectedEffortID = effort.id
                    }
                }
            }
        }
        .padding(.bottom, FlotillaSpacing.small)
        .frame(width: 350)
    }

    private func menuSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(FlotillaColors.textTertiary)
                .tracking(0.9)
                .padding(.horizontal, FlotillaSpacing.medium)
                .padding(.bottom, 3)
            content()
        }
    }

    private func selectionRow(
        title: String,
        detail: String,
        selected: Bool,
        tint: Color = FlotillaColors.accent,
        leading: AnyView? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let leading { leading.frame(width: 16) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(FlotillaColors.textPrimary)
                    Text(detail).font(.system(size: 10)).foregroundStyle(FlotillaColors.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(tint)
                    .opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, FlotillaSpacing.medium)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .background(selected ? tint.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
    }

    private func effortMeter(for effort: Effort) -> some View {
        VStack(spacing: 1.5) {
            ForEach(1...4, id: \.self) { rank in
                Capsule().fill(rank <= effort.rank ? effort.tint : FlotillaColors.separator).frame(width: 3, height: 3)
            }
        }
    }

    private func menuTitle(for concept: Concept) -> String {
        switch concept {
        case .spectrum: "Inline spectrum"
        case .dossier: "Two-line dossier"
        case .horizon: "Split horizon"
        case .signal: "Signal token"
        }
    }
}

#Preview("Merged model + effort concepts") {
    ModelEffortPickerConceptGallery()
        .preferredColorScheme(.dark)
}
