import SwiftUI
import SessionKit
import AgentKit
import DesignSystem

/// **Design 1 — Command Bar.** Spotlight, not a form.
///
/// One field carries the whole interaction. Typing `@` turns the field into a
/// project search; `/` turns it into an agent switch; anything else is the
/// goal. Everything already decided collapses into a single chip strip, and the
/// bottom edge states what will happen in one dim monospace line.
///
/// The panel stays short until a picker opens, so the common case — type, hit
/// return — never shows more chrome than a search bar.
struct CommandBarDesign: View {
    @Bindable var draft: SessionDraft
    @Bindable var store: AppStore
    let actions: SessionLauncherActions

    /// What the field is currently doing. `.goal` is the resting state; the
    /// other two are entered by typing a trigger character or clicking a chip.
    private enum Mode: Equatable {
        case goal
        case project(typed: Bool)
        case agent(typed: Bool)
    }

    @State private var mode: Mode = .goal
    @State private var chipQuery = ""
    @State private var highlightedIndex = 0
    @FocusState private var goalFocused: Bool
    @FocusState private var chipSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            queryRow
            if isPicking {
                Divider().overlay(FlotillaColors.separator)
                resultsList
            }
            Divider().overlay(FlotillaColors.separator)
            chipStrip
            if let error = store.lastCreationError {
                FlotillaBanner.error(error) { store.lastCreationError = nil }
                    .padding(.horizontal, FlotillaSpacing.medium)
                    .padding(.bottom, FlotillaSpacing.small)
            }
            summaryLine
        }
        // No solid fill beneath the glass: `FlotillaColors.surface` behind
        // `.glassEffect` would make the panel opaque and defeat the whole
        // point of a Liquid Glass, Spotlight-style surface. The material
        // itself is the background.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: FlotillaRadius.modal, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.modal, style: .continuous)
                .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
        }
        .flotillaShadow(.level3)
        .onChange(of: draft.goal) { _, _ in
            syncTypedTrigger(draft.goal)
            draft.syncModeFromGoal()
        }
        .onChange(of: mode) { _, _ in highlightedIndex = 0 }
        .onChange(of: chipQuery) { _, _ in highlightedIndex = 0 }
        .onAppear { goalFocused = true }
        .background { hiddenActions }
    }

    // MARK: - Query row

    private var queryRow: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            leadingGlyph

            TextField(placeholder, text: $draft.goal, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .regular))
                .lineLimit(1...4)
                .focused($goalFocused)
                .onKeyPress { press in handleKeyPress(press) }
                .accessibilityIdentifier("CreateSession.GoalField")

            if draft.isCreating {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("CreateSession.ProgressIndicator")
            }

            Button {
                actions.launch(true)
            } label: {
                Image(systemName: "return")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 24)
                    .background(FlotillaColors.accent, in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
                    .foregroundStyle(FlotillaColors.accentContent)
            }
            .buttonStyle(.plain)
            .disabled(!draft.canLaunch)
            .opacity(draft.canLaunch ? 1 : FlotillaStateOpacity.disabled)
            .help("Launch & open (↩)")
            .accessibilityIdentifier("CreateSession.CreateButton")
            .accessibilityLabel("Launch & Open")
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.medium)
    }

    /// Signals which mode the field is in without a mode banner: the agent's
    /// logo at rest, a magnifier or slash while a picker is open.
    @ViewBuilder
    private var leadingGlyph: some View {
        switch mode {
        case .goal:
            ProviderLogo(agent: draft.agent)
                .frame(width: FlotillaIconSize.large, height: FlotillaIconSize.large)
        case .project:
            Image(systemName: "magnifyingglass")
                .font(.system(size: FlotillaIconSize.medium, weight: .medium))
                .foregroundStyle(FlotillaColors.accent)
                .frame(width: FlotillaIconSize.large)
        case .agent:
            Image(systemName: "slash.circle")
                .font(.system(size: FlotillaIconSize.medium, weight: .medium))
                .foregroundStyle(FlotillaColors.accent)
                .frame(width: FlotillaIconSize.large)
        }
    }

    private var placeholder: String {
        switch mode {
        case .goal: "Describe the outcome…  @ for a project, / for an agent"
        case .project: "Search projects…"
        case .agent: "Switch agent…"
        }
    }

    // MARK: - Results

    private var isPicking: Bool {
        if case .goal = mode { return false }
        return true
    }

    @ViewBuilder
    private var resultsList: some View {
        ScrollView {
            VStack(spacing: 0) {
                switch mode {
                case .project(let typed):
                    projectResults(typed: typed)
                case .agent:
                    agentResults
                case .goal:
                    EmptyView()
                }
            }
            .padding(FlotillaSpacing.xSmall)
        }
        .frame(maxHeight: 190)
    }

    @ViewBuilder
    private func projectResults(typed: Bool) -> some View {
        // Typing `@goal text` filters from the main field; opening the same
        // list from the chip needs its own input, or the list is browse-only
        // while every keystroke goes to the objective.
        if !typed {
            HStack(spacing: FlotillaSpacing.small) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: FlotillaIconSize.xSmall))
                    .foregroundStyle(FlotillaColors.textTertiary)
                TextField("Filter projects…", text: $chipQuery)
                    .textFieldStyle(.plain)
                    .font(FlotillaTypography.caption)
                    .focused($chipSearchFocused)
                    .onKeyPress { press in handleKeyPress(press) }
                    .accessibilityIdentifier("CreateSession.ProjectFilter")
            }
            .padding(.horizontal, FlotillaSpacing.medium)
            .padding(.vertical, FlotillaSpacing.xSmall)
        }

        let choices = currentProjectChoices
        ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
            resultRow(
                symbol: choice.symbolName,
                title: choice.displayName,
                detail: choice.displayPath,
                isSelected: choice == draft.projectChoice,
                isHighlighted: index == highlightedIndex
            ) {
                draft.projectChoice = choice
                dismissPicker(clearingTypedTrigger: typed)
            }
            .accessibilityIdentifier(
                choice.isGeneral ? "CreateSession.Source.General" : "CreateSession.Project.\(choice.displayName)"
            )
        }

        resultRow(
            symbol: "folder.badge.plus",
            title: "Choose folder…",
            detail: nil,
            isSelected: false,
            isHighlighted: highlightedIndex == choices.count
        ) {
            dismissPicker(clearingTypedTrigger: typed)
            draft.chooseFolderFromPanel()
        }
        .accessibilityIdentifier("CreateSession.ChooseFolderButton")
    }

    @ViewBuilder
    private var agentResults: some View {
        ForEach(Array(currentAgentChoices.enumerated()), id: \.element.id) { index, kind in
            Button {
                draft.selectAgent(kind)
                dismissPicker(clearingTypedTrigger: isTypedAgentMode)
            } label: {
                HStack(spacing: FlotillaSpacing.small) {
                    ProviderLogo(agent: kind)
                        .frame(width: FlotillaIconSize.medium, height: FlotillaIconSize.medium)
                    Text(kind.displayName)
                        .font(FlotillaTypography.body)
                        .foregroundStyle(FlotillaColors.textPrimary)
                    Spacer()
                    if kind == draft.agent {
                        Image(systemName: "checkmark")
                            .font(FlotillaTypography.caption2.weight(.bold))
                            .foregroundStyle(FlotillaColors.accent)
                    }
                }
                .padding(.horizontal, FlotillaSpacing.medium)
                .padding(.vertical, FlotillaSpacing.small)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background {
                RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                    .fill(FlotillaColors.accent.opacity(index == highlightedIndex ? FlotillaStateOpacity.hover : 0))
            }
            .accessibilityIdentifier("CreateSession.Agent.\(kind.rawValue)")
        }
    }

    private func resultRow(
        symbol: String,
        title: String,
        detail: String?,
        isSelected: Bool,
        isHighlighted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: FlotillaSpacing.small) {
                Image(systemName: symbol)
                    .font(.system(size: FlotillaIconSize.small))
                    .foregroundStyle(isSelected ? FlotillaColors.accent : FlotillaColors.textTertiary)
                    .frame(width: FlotillaIconSize.medium)
                Text(title)
                    .font(FlotillaTypography.body)
                    .foregroundStyle(FlotillaColors.textPrimary)
                if let detail {
                    Text(detail)
                        .font(FlotillaTypography.caption2)
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: FlotillaSpacing.small)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(FlotillaTypography.caption2.weight(.bold))
                        .foregroundStyle(FlotillaColors.accent)
                }
            }
            .padding(.horizontal, FlotillaSpacing.medium)
            .padding(.vertical, FlotillaSpacing.small)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                .fill(FlotillaColors.accent.opacity(isHighlighted ? FlotillaStateOpacity.hover : 0))
        }
    }

    // MARK: - Chips

    private var chipStrip: some View {
        HStack(spacing: FlotillaSpacing.small) {
            projectChip
            agentDots
            ModelPickerView(agent: draft.agent, openCodeSubscription: draft.openCodeSubscription, model: $draft.model)
                .controlSize(.small)
                .fixedSize()
                .accessibilityIdentifier("CreateSession.ModelField")
            if draft.agent.supportsEffortSelection {
                EffortLevelPicker(
                    agent: draft.agent,
                    model: draft.model,
                    effort: $draft.effort,
                    accessibilityIdentifier: "CreateSession.EffortPicker"
                )
            }
            modeChip
            Spacer(minLength: 0)
            if draft.supportsWorktree { isolationToggle }
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
    }

    private var modeChip: some View {
        Menu {
            Button {
                draft.initialMode = .act
            } label: {
                Label("Act", systemImage: draft.initialMode == .act ? "checkmark" : "")
            }
            Button {
                draft.initialMode = .plan
            } label: {
                Label("Plan", systemImage: draft.initialMode == .plan ? "checkmark" : "")
            }
        } label: {
            HStack(spacing: FlotillaSpacing.xSmall) {
                Image(systemName: draft.initialMode == .plan ? "doc.text.magnifyingglass" : "play.fill")
                    .font(.system(size: FlotillaIconSize.xSmall))
                Text(draft.initialMode.displayName)
                    .font(FlotillaTypography.caption2.weight(.medium))
            }
            .foregroundStyle(draft.initialMode == .plan ? FlotillaColors.accent : FlotillaColors.textSecondary)
            .padding(.horizontal, FlotillaSpacing.small)
            .padding(.vertical, FlotillaSpacing.xSmall)
            .background(
                draft.initialMode == .plan ? FlotillaColors.accent.opacity(0.12) : FlotillaColors.surfaceElevated,
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(
                draft.initialMode == .plan ? FlotillaColors.accent.opacity(0.4) : FlotillaColors.separator,
                lineWidth: FlotillaBorderWidth.hairline
            ))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Session mode — Act lets the agent make changes; Plan restricts it to reading and proposing")
        .accessibilityIdentifier("CreateSession.ModePicker")
        .accessibilityValue(draft.initialMode.displayName)
    }

    private var projectChip: some View {
        Button {
            chipQuery = ""
            mode = isPicking ? .goal : .project(typed: false)
            chipSearchFocused = isPicking ? false : true
        } label: {
            HStack(spacing: FlotillaSpacing.xSmall) {
                Image(systemName: draft.projectChoice.symbolName)
                    .font(.system(size: FlotillaIconSize.xSmall))
                Text(draft.projectChoice.displayName)
                    .font(FlotillaTypography.caption2.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(draft.projectChoice.isGeneral ? FlotillaColors.textSecondary : FlotillaColors.accent)
            .padding(.horizontal, FlotillaSpacing.small)
            .padding(.vertical, FlotillaSpacing.xSmall)
            .background(
                FlotillaColors.surfaceElevated,
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline))
        }
        .buttonStyle(.plain)
        .help("Choose the workspace")
        .accessibilityIdentifier("CreateSession.ProjectPicker")
        .accessibilityValue(draft.projectChoice.displayName)
    }

    /// Four logos rather than a dropdown: with only four agents, a chip that
    /// hides three of them costs a click for no density gain.
    private var agentDots: some View {
        HStack(spacing: 2) {
            ForEach(AgentKind.allCases) { kind in
                Button {
                    draft.selectAgent(kind)
                } label: {
                    ProviderLogo(agent: kind)
                        .frame(width: FlotillaIconSize.medium, height: FlotillaIconSize.medium)
                        .padding(FlotillaSpacing.xSmall)
                        .background(
                            kind == draft.agent ? FlotillaColors.accent.opacity(FlotillaStateOpacity.selected) : .clear,
                            in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                                .strokeBorder(
                                    kind == draft.agent ? FlotillaColors.accent.opacity(0.6) : .clear,
                                    lineWidth: FlotillaBorderWidth.hairline
                                )
                        }
                        // Unselected logos stay legible rather than fading to
                        // near-invisible on the dark surface.
                        .opacity(kind == draft.agent ? 1 : 0.78)
                }
                .buttonStyle(.plain)
                .help(kind.displayName)
                .accessibilityIdentifier("CreateSession.Agent.\(kind.rawValue)")
                .accessibilityLabel(kind.displayName)
            }
        }
    }

    private var isolationToggle: some View {
        HStack(spacing: 1) {
            isolationSegment(
                title: "Checkout",
                symbol: "shippingbox",
                isActive: !draft.createWorktree,
                identifier: "CreateSession.Checkout.Main"
            ) { draft.createWorktree = false }

            isolationSegment(
                title: "Worktree",
                symbol: "arrow.triangle.branch",
                isActive: draft.createWorktree,
                identifier: "CreateSession.Checkout.Worktree"
            ) { draft.createWorktree = true }
        }
        .padding(1)
        .background(FlotillaColors.surfaceElevated, in: Capsule())
        .overlay(Capsule().strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline))
    }

    private func isolationSegment(
        title: String,
        symbol: String,
        isActive: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: FlotillaSpacing.xSmall) {
                if symbol == "arrow.triangle.branch" {
                    GitBranchIcon(size: FlotillaIconSize.xSmall)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: FlotillaIconSize.xSmall))
                }
                Text(title)
                    .font(FlotillaTypography.caption3.weight(.medium))
            }
            .foregroundStyle(isActive ? FlotillaColors.accentContent : FlotillaColors.textTertiary)
            .padding(.horizontal, FlotillaSpacing.small)
            .padding(.vertical, 3)
            .background(isActive ? FlotillaColors.accent : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    // MARK: - Summary

    private var summaryLine: some View {
        let preview = draft.preview
        return HStack(spacing: FlotillaSpacing.small) {
            if preview.isWorktree {
                GitBranchIcon(size: FlotillaIconSize.xSmall)
                    .foregroundStyle(FlotillaColors.statusReady)
            } else {
                Image(systemName: "shippingbox")
                    .font(.system(size: FlotillaIconSize.xSmall))
                    .foregroundStyle(FlotillaColors.textTertiary)
            }

            Text(preview.displayBranch ?? preview.displayDirectory)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(FlotillaColors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text("·")
                .foregroundStyle(FlotillaColors.textTertiary)

            Text(preview.command)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(FlotillaColors.textTertiary)
                .lineLimit(1)

            if preview.sharedCheckoutWarning != nil {
                Label("shared checkout", systemImage: "exclamationmark.triangle.fill")
                    .font(FlotillaTypography.caption3.weight(.medium))
                    .foregroundStyle(FlotillaColors.warning)
                    .lineLimit(1)
                    .help(preview.sharedCheckoutWarning ?? "")
            }

            Spacer(minLength: 0)

            // Names the outcome rather than the mechanism, matching
            // `LaunchpadDesign`. Kept in the bar's own recessive register —
            // this is a Spotlight-style strip, not a dialog — but no longer
            // dimmer than the primary action it sits beside.
            Button("Launch & Stay Here") { actions.launch(false) }
                .buttonStyle(.plain)
                .font(FlotillaTypography.caption3.weight(.medium))
                .foregroundStyle(FlotillaColors.textPrimary)
                .disabled(!draft.canLaunch)
                .accessibilityIdentifier("CreateSession.BackgroundButton")

            // Esc dismisses, but a Spotlight panel still needs a target a
            // pointer or VoiceOver can actually reach.
            Button("Esc") { actions.cancel() }
                .buttonStyle(.plain)
                .font(FlotillaTypography.caption3.weight(.medium))
                .foregroundStyle(FlotillaColors.textTertiary)
                .accessibilityIdentifier("CreateSession.CancelButton")
                .accessibilityLabel("Cancel")
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.small)
        .background(FlotillaColors.surfaceElevated.opacity(0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CreateSession.LaunchSummary")
    }

    // MARK: - Trigger handling

    private var isTypedAgentMode: Bool {
        if case .agent(let typed) = mode { return typed }
        return false
    }

    /// `@` and `/` only mean anything as the *first* character. Mid-sentence
    /// they are ordinary text — an email address in a goal must not hijack the
    /// field.
    private func syncTypedTrigger(_ text: String) {
        if text.hasPrefix("@") {
            mode = .project(typed: true)
        } else if text.hasPrefix("/") {
            mode = .agent(typed: true)
        } else if case .project(true) = mode {
            mode = .goal
        } else if case .agent(true) = mode {
            mode = .goal
        }
        highlightedIndex = 0
    }

    /// A typed trigger leaves `@query` sitting in the goal; it is scaffolding
    /// for the search, not part of the objective, so it is removed once the
    /// search resolves.
    private func dismissPicker(clearingTypedTrigger: Bool) {
        if clearingTypedTrigger { draft.goal = "" }
        mode = .goal
        goalFocused = true
    }

    /// Closes the picker without acting on it — the `@`/`/` scaffolding text
    /// goes with it, same as a resolved search, or Escape would just reopen
    /// the picker it was meant to close.
    private func cancelPicker() {
        switch mode {
        case .project(true), .agent(true):
            dismissPicker(clearingTypedTrigger: true)
        default:
            dismissPicker(clearingTypedTrigger: false)
        }
    }

    // MARK: - Keyboard navigation

    /// The project choices for whichever query is currently active — typed
    /// `@query` in the goal field, or the chip's own filter field.
    private var currentProjectChoices: [ProjectChoice] {
        guard case .project(let typed) = mode else { return [] }
        let query = typed ? String(draft.goal.dropFirst()) : chipQuery
        return draft.filteredChoices(query: query)
    }

    /// The agent choices for whichever query is currently active — typed
    /// `/query` in the goal field filters by name, same as `@query` does for
    /// projects; an untyped (chip-opened) picker shows every agent.
    private var currentAgentChoices: [AgentKind] {
        guard case .agent(let typed) = mode else { return [] }
        guard typed else { return AgentKind.allCases }
        let query = String(draft.goal.dropFirst()).trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return AgentKind.allCases }
        return AgentKind.allCases.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    /// Row count for the open picker, including the trailing "Choose
    /// folder…" row in project mode — that row is a valid arrow-key stop too.
    private var pickerRowCount: Int {
        switch mode {
        case .goal: 0
        case .project: currentProjectChoices.count + 1
        case .agent: currentAgentChoices.count
        }
    }

    private func moveHighlight(by delta: Int) {
        let count = pickerRowCount
        guard count > 0 else { return }
        highlightedIndex = min(max(highlightedIndex + delta, 0), count - 1)
    }

    /// Activates whatever row is currently highlighted — the Enter-key
    /// equivalent of clicking it.
    private func selectHighlighted() {
        switch mode {
        case .goal:
            break
        case .project(let typed):
            let choices = currentProjectChoices
            if highlightedIndex < choices.count {
                draft.projectChoice = choices[highlightedIndex]
                dismissPicker(clearingTypedTrigger: typed)
            } else {
                dismissPicker(clearingTypedTrigger: typed)
                draft.chooseFolderFromPanel()
            }
        case .agent:
            let kinds = currentAgentChoices
            if highlightedIndex < kinds.count {
                draft.selectAgent(kinds[highlightedIndex])
                dismissPicker(clearingTypedTrigger: isTypedAgentMode)
            }
        }
    }

    /// Shared by the goal field and the chip's project-filter field: arrow
    /// keys move the highlight, Return activates the highlighted row while a
    /// picker is open (so `@flotilla` + Return launches into that project
    /// without ever touching the mouse), and Escape backs out of the picker
    /// before it backs out of the whole overlay.
    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        if isPicking {
            switch press.key {
            case .downArrow:
                moveHighlight(by: 1)
                return .handled
            case .upArrow:
                moveHighlight(by: -1)
                return .handled
            case .return:
                if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                    return .ignored
                }
                selectHighlighted()
                return .handled
            case .escape:
                cancelPicker()
                return .handled
            default:
                return .ignored
            }
        }

        if press.key == .return {
            if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                return .ignored
            }
            if draft.canLaunch {
                actions.launch(true)
            }
            return .handled
        } else if press.key == .escape {
            actions.cancel()
            return .handled
        }
        return .ignored
    }

    private var hiddenActions: some View {
        Group {
            Button("") { actions.launch(true) }
                .keyboardShortcut(.return, modifiers: .command)
            Button("") { actions.launch(false) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("") { actions.cancel() }
                .keyboardShortcut(.cancelAction)
                .accessibilityHidden(true)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }
}
