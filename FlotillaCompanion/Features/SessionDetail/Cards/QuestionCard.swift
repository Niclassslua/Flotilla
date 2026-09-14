import SwiftUI
import DesignSystem
import CompanionKit

/// Steps through every question; nothing is sent until Submit, as one payload.
struct QuestionCard: View {
    let context: CardContext
    let steps: [QuestionStep]
    let maxHeight: CGFloat

    @Environment(CompanionStore.self) private var store
    @State private var stepIndex = 0
    @State private var selections: [String: [String]] = [:]
    @State private var otherEnabled: Set<String> = []
    @State private var otherText: [String: String] = [:]
    @State private var isSending = false
    @FocusState private var isOtherFocused: Bool

    var body: some View {
        let step = steps[min(stepIndex, steps.count - 1)]

        CardContainer(context: context, title: "Question", systemImage: "questionmark.bubble.fill") {
            HStack {
                Text(step.header.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FlotillaColors.textTertiary)
                Spacer()
                if steps.count > 1 {
                    Text("Question \(stepIndex + 1) of \(steps.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(step.prompt)
                        .font(.headline)
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if step.allowsMultiple {
                        Text("Choose any")
                            .font(.caption)
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }
                    ForEach(step.options, id: \.label) { option in
                        OptionButton(
                            label: option.label,
                            description: option.description,
                            isSelected: selections[step.id, default: []].contains(option.label),
                            allowsMultiple: step.allowsMultiple
                        ) {
                            toggle(option.label, in: step)
                        }
                    }
                    if step.allowsFreeText != false {
                        OptionButton(
                            label: "Other",
                            description: nil,
                            isSelected: otherEnabled.contains(step.id),
                            allowsMultiple: step.allowsMultiple
                        ) {
                            toggleOther(in: step)
                        }
                    }
                    if otherEnabled.contains(step.id) {
                        TextField("Your answer", text: Binding(
                            get: { otherText[step.id, default: ""] },
                            set: { otherText[step.id] = $0 }
                        ), axis: .vertical)
                        .lineLimit(1...4)
                        .focused($isOtherFocused)
                        .padding(10)
                        .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: max(160, maxHeight - 150))
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if stepIndex > 0 {
                    Button {
                        withAnimation(.snappy) { stepIndex -= 1 }
                    } label: {
                        Text("Back").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
                if stepIndex < steps.count - 1 {
                    Button {
                        withAnimation(.snappy) { stepIndex += 1 }
                    } label: {
                        Text("Next").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .disabled(!isAnswered(step))
                } else {
                    Button(action: submit) {
                        Text("Submit").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(FlotillaColors.accent)
                    .disabled(!steps.allSatisfy(isAnswered) || isSending)
                    .accessibilityIdentifier("QuestionCard.Submit")
                }
            }
            .controlSize(.large)
        }
        .sensoryFeedback(.selection, trigger: selections)
    }

    private func isAnswered(_ step: QuestionStep) -> Bool {
        let hasOther = otherEnabled.contains(step.id) && !otherText[step.id, default: ""].trimmingCharacters(in: .whitespaces).isEmpty
        return !selections[step.id, default: []].isEmpty || hasOther
    }

    private func toggle(_ label: String, in step: QuestionStep) {
        var current = selections[step.id, default: []]
        if step.allowsMultiple {
            if let index = current.firstIndex(of: label) { current.remove(at: index) } else { current.append(label) }
        } else {
            current = current == [label] ? [] : [label]
            otherEnabled.remove(step.id)
        }
        selections[step.id] = current
    }

    private func toggleOther(in step: QuestionStep) {
        if otherEnabled.contains(step.id) {
            otherEnabled.remove(step.id)
        } else {
            otherEnabled.insert(step.id)
            if !step.allowsMultiple { selections[step.id] = [] }
            isOtherFocused = true
        }
    }

    private func submit() {
        isSending = true
        let answers = steps.map { step in
            let other = otherEnabled.contains(step.id) ? otherText[step.id]?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            return QuestionAnswer(stepID: step.id, selected: selections[step.id, default: []], other: other?.isEmpty == false ? other : nil)
        }
        Task {
            _ = await store.answer(context.interaction.id, in: context.sessionID, with: .questionAnswers(answers))
            isSending = false
        }
    }
}

private struct OptionButton: View {
    let label: String
    let description: String?
    let isSelected: Bool
    let allowsMultiple: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(isSelected ? FlotillaColors.accent : FlotillaColors.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.body.weight(.medium))
                        .foregroundStyle(FlotillaColors.textPrimary)
                    if let description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(FlotillaColors.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 48)
            .background(
                RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                    .fill(isSelected ? FlotillaColors.surfaceElevated : FlotillaColors.surface.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                    .strokeBorder(isSelected ? FlotillaColors.accent.opacity(0.7) : FlotillaColors.separator, lineWidth: isSelected ? 1.5 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var symbol: String {
        switch (allowsMultiple, isSelected) {
        case (true, true): "checkmark.square.fill"
        case (true, false): "square"
        case (false, true): "largecircle.fill.circle"
        case (false, false): "circle"
        }
    }
}
