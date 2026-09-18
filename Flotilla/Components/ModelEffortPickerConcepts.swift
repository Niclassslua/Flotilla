import SwiftUI
import DesignSystem

/// A decision board for the single modal opened by a unified model and
/// reasoning picker. Each treatment lets both choices change in one surface.
struct ModelEffortPickerConceptGallery: View {
    private struct Model: Identifiable { let id, name, subtitle, symbol: String }
    private struct Effort: Identifiable {
        let id, name, detail: String
        let tint: Color
        let rank: Int
    }

    private let models = [
        Model(id: "gpt", name: "GPT-5.4", subtitle: "Balanced coding", symbol: "cpu"),
        Model(id: "opus", name: "Claude Opus 4.6", subtitle: "Deep planning", symbol: "brain"),
        Model(id: "flash", name: "Gemini 3.7 Flash", subtitle: "Fast iteration", symbol: "bolt")
    ]
    private let efforts = [
        Effort(id: "low", name: "Low", detail: "Quick response", tint: Color(red: 0.30, green: 0.55, blue: 0.68), rank: 1),
        Effort(id: "medium", name: "Medium", detail: "Balanced depth", tint: FlotillaColors.statusReady, rank: 2),
        Effort(id: "high", name: "High", detail: "More analysis", tint: FlotillaColors.warning, rank: 3),
        Effort(id: "xhigh", name: "X-High", detail: "Maximum care", tint: FlotillaColors.accent, rank: 4)
    ]

    @State private var modelID = "gpt"
    @State private var effortID = "xhigh"
    private var model: Model { models.first { $0.id == modelID } ?? models[0] }
    private var effort: Effort { efforts.first { $0.id == effortID } ?? efforts[0] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FlotillaSpacing.xLarge) {
                header
                modalCard("01", "Model directory", "A navigation rail makes the model decision browseable; effort stays in that model’s inspector.") { directoryModal }
                modalCard("02", "Focus sheet", "A single editorial configuration surface: the current model is clear, effort is the deliberate second decision.") { focusModal }
                modalCard("03", "Compatibility matrix", "Best for power users: model and effort become one visible compatibility system rather than serial fields.") { matrixModal }
                modalCard("04", "Command inspector", "A command-palette rhythm: search and scan on the left, explanation and commitment on the right.") { commandModal }
            }
            .padding(FlotillaSpacing.xxLarge)
        }
        .frame(width: 880, height: 900)
        .background(FlotillaColors.surface)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            Text("ONE PICKER · ONE MODAL")
                .font(.system(size: 10, weight: .bold)).tracking(1.4).foregroundStyle(FlotillaColors.accent)
            HStack(alignment: .lastTextBaseline) {
                Text("Model + reasoning modal")
                    .font(.system(size: 27, weight: .bold, design: .rounded)).foregroundStyle(FlotillaColors.textPrimary)
                Spacer(minLength: 0)
                restingTrigger
            }
            Text("The resting chip only states the configuration. All selection work happens in one composed modal.")
                .font(.system(size: 13)).foregroundStyle(FlotillaColors.textSecondary)
        }
    }

    private var restingTrigger: some View {
        HStack(spacing: 7) {
            Image(systemName: "slider.horizontal.3").foregroundStyle(FlotillaColors.textTertiary)
            Text("\(model.name) · \(effort.name)").font(.system(size: 12, weight: .semibold))
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(FlotillaColors.textTertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(FlotillaColors.surfaceElevated, in: Capsule())
        .overlay { Capsule().strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline) }
    }

    private func modalCard<Content: View>(_ number: String, _ title: String, _ note: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
            HStack(alignment: .firstTextBaseline) {
                Text(number).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(FlotillaColors.accent)
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(FlotillaColors.textPrimary)
                Spacer(minLength: 0)
                Text("ONE MODAL").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(FlotillaColors.textTertiary)
            }
            content()
            Text(note).font(.system(size: 12)).foregroundStyle(FlotillaColors.textSecondary)
        }
        .padding(FlotillaSpacing.large)
        .background(FlotillaColors.surfaceElevated.opacity(0.7), in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous).strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline) }
    }

    private var directoryModal: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                modalHeader("Choose a model", "3 available")
                ForEach(models) { modelRow($0, compact: true) }
                Spacer(minLength: 0)
                Text("Model availability updates with your agent.").font(.system(size: 9)).foregroundStyle(FlotillaColors.textTertiary).padding(10)
            }
            .padding(10).frame(width: 230).background(FlotillaColors.surface.opacity(0.55))
            VStack(alignment: .leading, spacing: 10) {
                modalHeader("Reasoning effort", model.name)
                Text("How carefully should \(model.name) reason before acting?").font(.system(size: 12)).foregroundStyle(FlotillaColors.textSecondary)
                VStack(spacing: 3) { ForEach(efforts) { effortRow($0, description: true) } }
                summaryFooter
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 240).clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous).strokeBorder(FlotillaColors.separatorStrong, lineWidth: FlotillaBorderWidth.hairline) }
    }

    private var focusModal: some View {
        VStack(alignment: .leading, spacing: 10) {
            modalHeader("Configure this session", "Esc to cancel")
            HStack(spacing: 10) {
                Image(systemName: model.symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(FlotillaColors.accent)
                    .frame(width: 38, height: 38).background(FlotillaColors.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name).font(.system(size: 15, weight: .semibold))
                    Text(model.subtitle).font(.system(size: 11)).foregroundStyle(FlotillaColors.textSecondary)
                }
                Spacer(minLength: 0)
                Text("Change model").font(.system(size: 11, weight: .semibold)).foregroundStyle(FlotillaColors.accent)
            }
            .padding(10).background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
            Text("REASONING DEPTH").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(FlotillaColors.textTertiary)
            HStack(spacing: 6) {
                ForEach(efforts) { option in
                    Button { effortID = option.id } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            meter(option)
                            Text(option.name).font(.system(size: 11, weight: .semibold))
                            Text(option.detail).font(.system(size: 9)).foregroundStyle(FlotillaColors.textSecondary)
                        }
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(option.id == effortID ? option.tint.opacity(0.14) : FlotillaColors.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous).strokeBorder(option.id == effortID ? option.tint.opacity(0.7) : FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline) }
                    }.buttonStyle(.plain)
                }
            }
            summaryFooter
        }
        .padding(12).background(FlotillaColors.surfaceElevated, in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous).strokeBorder(FlotillaColors.separatorStrong, lineWidth: FlotillaBorderWidth.hairline) }
    }

    private var matrixModal: some View {
        VStack(alignment: .leading, spacing: 8) {
            modalHeader("Find the right balance", "Models × effort")
            HStack(spacing: 0) {
                Text("MODEL").frame(width: 150, alignment: .leading)
                ForEach(efforts) { Text($0.name).font(.system(size: 10, weight: .semibold)).foregroundStyle($0.tint).frame(maxWidth: .infinity) }
            }
            .font(.system(size: 9, weight: .bold)).foregroundStyle(FlotillaColors.textTertiary).padding(.horizontal, 10)
            ForEach(models) { option in
                HStack(spacing: 0) {
                    Button { modelID = option.id } label: {
                        HStack(spacing: 6) {
                            Image(systemName: option.symbol).font(.system(size: 10))
                            Text(option.name).font(.system(size: 11, weight: .semibold))
                        }.foregroundStyle(option.id == modelID ? FlotillaColors.textPrimary : FlotillaColors.textSecondary).frame(width: 150, alignment: .leading)
                    }.buttonStyle(.plain)
                    ForEach(efforts) { level in
                        Button { modelID = option.id; effortID = level.id } label: {
                            Image(systemName: option.id == modelID && level.id == effortID ? "checkmark" : "circle")
                                .font(.system(size: 10, weight: .bold)).foregroundStyle(option.id == modelID && level.id == effortID ? level.tint : FlotillaColors.separatorStrong).frame(maxWidth: .infinity, minHeight: 30)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).background(option.id == modelID ? FlotillaColors.surface.opacity(0.8) : .clear, in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
            }
            summaryFooter
        }
        .padding(12).background(FlotillaColors.surfaceElevated, in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous).strokeBorder(FlotillaColors.separatorStrong, lineWidth: FlotillaBorderWidth.hairline) }
    }

    private var commandModal: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(FlotillaColors.textTertiary)
                    Text("Search models").font(.system(size: 12)).foregroundStyle(FlotillaColors.textTertiary)
                }.padding(9).background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
                ForEach(models) { modelRow($0, compact: false) }
            }.padding(12).frame(width: 310)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                modalHeader("Session profile", "Ready to launch")
                Text(model.name).font(.system(size: 16, weight: .semibold))
                Text(model.subtitle).font(.system(size: 11)).foregroundStyle(FlotillaColors.textSecondary)
                Divider()
                Text("REASONING").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(FlotillaColors.textTertiary)
                ForEach(efforts) { effortRow($0, description: false) }
                summaryFooter
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 260).clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous).strokeBorder(FlotillaColors.separatorStrong, lineWidth: FlotillaBorderWidth.hairline) }
    }

    private func modalHeader(_ title: String, _ detail: String) -> some View {
        HStack { Text(title).font(.system(size: 13, weight: .semibold)); Spacer(minLength: 0); Text(detail).font(.system(size: 10)).foregroundStyle(FlotillaColors.textTertiary) }
            .foregroundStyle(FlotillaColors.textPrimary)
    }

    private func modelRow(_ option: Model, compact: Bool) -> some View {
        Button { modelID = option.id } label: {
            HStack(spacing: 8) {
                Image(systemName: option.symbol).font(.system(size: 11, weight: .medium)).frame(width: 15)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.name).font(.system(size: 11, weight: .semibold))
                    if !compact { Text(option.subtitle).font(.system(size: 10)).foregroundStyle(FlotillaColors.textSecondary) }
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).opacity(option.id == modelID ? 1 : 0)
            }
            .foregroundStyle(option.id == modelID ? FlotillaColors.accent : FlotillaColors.textPrimary).padding(.horizontal, 9).padding(.vertical, compact ? 7 : 8)
            .background(option.id == modelID ? FlotillaColors.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
        }.buttonStyle(.plain)
    }

    private func effortRow(_ option: Effort, description: Bool) -> some View {
        Button { effortID = option.id } label: {
            HStack(spacing: 8) {
                meter(option).frame(width: 18, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.name).font(.system(size: 11, weight: .semibold))
                    if description { Text(option.detail).font(.system(size: 10)).foregroundStyle(FlotillaColors.textSecondary) }
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).opacity(option.id == effortID ? 1 : 0)
            }
            .foregroundStyle(option.id == effortID ? option.tint : FlotillaColors.textPrimary).padding(.horizontal, 8).padding(.vertical, 5)
            .background(option.id == effortID ? option.tint.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
        }.buttonStyle(.plain)
    }

    private func meter(_ option: Effort) -> some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(1...4, id: \.self) { index in
                Capsule().fill(index <= option.rank ? option.tint : FlotillaColors.separatorStrong.opacity(0.45)).frame(width: 2.5, height: CGFloat(4 + index * 2))
            }
        }.frame(height: 13, alignment: .bottom)
    }

    private var summaryFooter: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("SESSION WILL USE").font(.system(size: 8, weight: .bold)).tracking(0.7).foregroundStyle(FlotillaColors.textTertiary)
                Text("\(model.name) · \(effort.name)").font(.system(size: 11, weight: .semibold))
            }
            Spacer(minLength: 0)
            Text("Done").font(.system(size: 11, weight: .bold)).foregroundStyle(FlotillaColors.accentContent)
                .padding(.horizontal, 10).padding(.vertical, 6).background(FlotillaColors.accent, in: Capsule())
        }.padding(.top, 4).foregroundStyle(FlotillaColors.textPrimary)
    }
}

#Preview("Unified picker modal concepts") {
    ModelEffortPickerConceptGallery().preferredColorScheme(.dark)
}
