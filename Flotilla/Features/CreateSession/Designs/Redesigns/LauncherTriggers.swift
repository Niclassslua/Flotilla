import SwiftUI
import SessionKit
import AgentKit
import DesignSystem

/// The Command Bar's typed shortcuts, shared by every newer launcher style:
/// a goal starting with `@` searches projects, one starting with `/` switches
/// agents. Only the *first* character counts — mid-sentence they are ordinary
/// text, so an email address in a goal can't hijack the field.
///
/// Arrow keys move the highlight, Return picks, Escape backs out of the
/// search before it backs out of the window. The `@query` / `/query` text is
/// scaffolding, not part of the objective, so it's cleared once the search
/// resolves or is cancelled.
@Observable
@MainActor
final class LauncherTriggers {
    enum Mode: Equatable {
        case goal
        case project
        case agent
    }

    private(set) var mode: Mode = .goal
    private(set) var highlightedIndex = 0

    var isPicking: Bool { mode != .goal }

    func sync(goal: String) {
        let newMode: Mode = goal.hasPrefix("@") ? .project : goal.hasPrefix("/") ? .agent : .goal
        // `/plan` is a goal command, not an agent search; `SessionDraft`
        // handles it. Leave agent mode the moment it can only be that.
        if newMode == .agent, goal.lowercased().hasPrefix("/plan") {
            mode = .goal
        } else {
            mode = newMode
        }
        highlightedIndex = 0
    }

    func projectChoices(_ draft: SessionDraft) -> [ProjectChoice] {
        guard mode == .project else { return [] }
        return draft.filteredChoices(query: String(draft.goal.dropFirst()))
    }

    func agentChoices(_ draft: SessionDraft) -> [AgentKind] {
        guard mode == .agent else { return [] }
        let query = String(draft.goal.dropFirst()).trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return AgentKind.allCases }
        return AgentKind.allCases.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    /// Includes the trailing "Choose folder…" row in project mode — it's a
    /// valid arrow-key stop too.
    private func rowCount(_ draft: SessionDraft) -> Int {
        switch mode {
        case .goal: 0
        case .project: projectChoices(draft).count + 1
        case .agent: agentChoices(draft).count
        }
    }

    func pick(_ choice: ProjectChoice, in draft: SessionDraft) {
        draft.projectChoice = choice
        resolve(draft)
    }

    func pick(_ agent: AgentKind, in draft: SessionDraft) {
        draft.selectAgent(agent)
        resolve(draft)
    }

    func chooseFolder(in draft: SessionDraft) {
        resolve(draft)
        draft.chooseFolderFromPanel()
    }

    private func resolve(_ draft: SessionDraft) {
        draft.goal = ""
        mode = .goal
        highlightedIndex = 0
    }

    /// Returns `.ignored` for anything that isn't a trigger key, so the
    /// caller's own Return/Escape handling runs.
    func handle(_ press: KeyPress, draft: SessionDraft) -> KeyPress.Result {
        guard isPicking else { return .ignored }
        switch press.key {
        case .downArrow:
            highlightedIndex = min(highlightedIndex + 1, max(rowCount(draft) - 1, 0))
            return .handled
        case .upArrow:
            highlightedIndex = max(highlightedIndex - 1, 0)
            return .handled
        case .return:
            if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
            selectHighlighted(draft)
            return .handled
        case .escape:
            resolve(draft)
            return .handled
        default:
            return .ignored
        }
    }

    private func selectHighlighted(_ draft: SessionDraft) {
        switch mode {
        case .goal:
            break
        case .project:
            let choices = projectChoices(draft)
            if highlightedIndex < choices.count {
                pick(choices[highlightedIndex], in: draft)
            } else {
                chooseFolder(in: draft)
            }
        case .agent:
            let kinds = agentChoices(draft)
            if highlightedIndex < kinds.count {
                pick(kinds[highlightedIndex], in: draft)
            }
        }
    }
}

/// The dropdown shown under the goal field while a trigger search is open.
struct LauncherTriggerResults: View {
    let triggers: LauncherTriggers
    @Bindable var draft: SessionDraft

    var body: some View {
        ScrollView {
            VStack(spacing: 1) {
                switch triggers.mode {
                case .project:
                    let choices = triggers.projectChoices(draft)
                    ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                        row(
                            highlighted: index == triggers.highlightedIndex,
                            selected: choice == draft.projectChoice,
                            identifier: choice.isGeneral ? "CreateSession.Source.General" : "CreateSession.Project.\(choice.displayName)"
                        ) {
                            triggers.pick(choice, in: draft)
                        } label: {
                            Image(systemName: choice.symbolName)
                                .font(.system(size: FlotillaIconSize.small))
                                .foregroundStyle(FlotillaColors.textTertiary)
                                .frame(width: FlotillaIconSize.medium)
                            Text(choice.displayName)
                                .font(FlotillaTypography.callout)
                                .foregroundStyle(FlotillaColors.textPrimary)
                            if let path = choice.displayPath {
                                Text(path)
                                    .font(FlotillaTypography.caption2)
                                    .foregroundStyle(FlotillaColors.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                    }
                    row(
                        highlighted: triggers.highlightedIndex == choices.count,
                        selected: false,
                        identifier: "CreateSession.ChooseFolderButton"
                    ) {
                        triggers.chooseFolder(in: draft)
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: FlotillaIconSize.small))
                            .foregroundStyle(FlotillaColors.textTertiary)
                            .frame(width: FlotillaIconSize.medium)
                        Text("Choose folder…")
                            .font(FlotillaTypography.callout)
                            .foregroundStyle(FlotillaColors.textSecondary)
                    }
                case .agent:
                    ForEach(Array(triggers.agentChoices(draft).enumerated()), id: \.element.id) { index, kind in
                        row(
                            highlighted: index == triggers.highlightedIndex,
                            selected: kind == draft.agent,
                            identifier: "CreateSession.Agent.\(kind.rawValue)"
                        ) {
                            triggers.pick(kind, in: draft)
                        } label: {
                            ProviderLogo(agent: kind)
                                .frame(width: FlotillaIconSize.medium, height: FlotillaIconSize.medium)
                            Text(kind.displayName)
                                .font(FlotillaTypography.callout)
                                .foregroundStyle(FlotillaColors.textPrimary)
                        }
                    }
                case .goal:
                    EmptyView()
                }
            }
            .padding(FlotillaSpacing.xSmall)
        }
        .frame(maxHeight: 200)
        .fixedSize(horizontal: false, vertical: true)
        .background(FlotillaColors.surfaceElevated.opacity(0.5), in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
        }
    }

    private func row<Label: View>(
        highlighted: Bool,
        selected: Bool,
        identifier: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            HStack(spacing: FlotillaSpacing.small) {
                label()
                Spacer(minLength: FlotillaSpacing.small)
                if selected {
                    Image(systemName: "checkmark")
                        .font(FlotillaTypography.caption2.weight(.bold))
                        .foregroundStyle(FlotillaColors.accent)
                }
            }
            .padding(.horizontal, FlotillaSpacing.small)
            .frame(height: 28)
            .background(
                FlotillaColors.accent.opacity(highlighted ? FlotillaStateOpacity.selected : 0),
                in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
