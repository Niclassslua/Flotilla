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
        .onChange(of: draft.goal) { _, newValue in syncTypedTrigger(newValue) }
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
                .onSubmit { actions.launch(true) }
                // Belt and suspenders alongside `EscapeKeyCatcher` at the
                // presentation layer: this field's multi-line `axis: .vertical`
                // TextField is NSTextView-backed, and NSTextView can consume
                // Escape internally via its own `cancelOperation:` handling
                // before any ancestor `.onExitCommand`/`.keyboardShortcut`
                // ever sees it.
                .onKeyPress(.escape) {
                    actions.cancel()
                    return .handled
                }
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
            .help("Launch session (↩)")
            .accessibilityIdentifier("CreateSession.CreateButton")
            .accessibilityLabel("Launch Session")
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
                    .accessibilityIdentifier("CreateSession.ProjectFilter")
            }
            .padding(.horizontal, FlotillaSpacing.medium)
            .padding(.vertical, FlotillaSpacing.xSmall)
        }

        let query = typed ? String(draft.goal.dropFirst()) : chipQuery
        ForEach(draft.filteredChoices(query: query)) { choice in
            resultRow(
                symbol: choice.symbolName,
                title: choice.displayName,
                detail: choice.displayPath,
                isSelected: choice == draft.projectChoice
            ) {
                draft.projectChoice = choice
                dismissPicker(clearingTypedTrigger: typed)
            }
            .accessibilityIdentifier(
                choice.isGeneral ? "CreateSession.Source.General" : "CreateSession.Project.\(choice.displayName)"
            )
        }

        resultRow(symbol: "folder.badge.plus", title: "Choose folder…", detail: nil, isSelected: false) {
            dismissPicker(clearingTypedTrigger: typed)
            draft.chooseFolderFromPanel()
        }
        .accessibilityIdentifier("CreateSession.ChooseFolderButton")
    }

    @ViewBuilder
    private var agentResults: some View {
        ForEach(AgentKind.allCases) { kind in
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
            .accessibilityIdentifier("CreateSession.Agent.\(kind.rawValue)")
        }
    }

    private func resultRow(
        symbol: String,
        title: String,
        detail: String?,
        isSelected: Bool,
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
            Spacer(minLength: 0)
            if draft.supportsWorktree { isolationToggle }
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
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
                Image(systemName: symbol)
                    .font(.system(size: FlotillaIconSize.xSmall))
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
            Image(systemName: preview.isWorktree ? "arrow.triangle.branch" : "shippingbox")
                .font(.system(size: FlotillaIconSize.xSmall))
                .foregroundStyle(preview.isWorktree ? FlotillaColors.statusReady : FlotillaColors.textTertiary)

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

            Button("Background") { actions.launch(false) }
                .buttonStyle(.plain)
                .font(FlotillaTypography.caption3.weight(.medium))
                .foregroundStyle(FlotillaColors.textSecondary)
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
    }

    /// A typed trigger leaves `@query` sitting in the goal; it is scaffolding
    /// for the search, not part of the objective, so it is removed once the
    /// search resolves.
    private func dismissPicker(clearingTypedTrigger: Bool) {
        if clearingTypedTrigger { draft.goal = "" }
        mode = .goal
        goalFocused = true
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
