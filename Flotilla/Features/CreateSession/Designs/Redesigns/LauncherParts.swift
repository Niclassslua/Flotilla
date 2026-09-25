import SwiftUI
import SessionKit
import AgentKit
import DesignSystem
// MARK: - Surface

private struct LauncherSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .flotillaFloatingCard()
            .flotillaShadow(.level3)
    }
}

extension View {
    func launcherSurface() -> some View { modifier(LauncherSurface()) }
}

// MARK: - Small pieces

/// A key legend: `↩`, `⇧⌘↩`, `esc`.
struct LauncherKeycap: View {
    let text: String
    var onAccent = false

    init(_ text: String, onAccent: Bool = false) {
        self.text = text
        self.onAccent = onAccent
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(onAccent ? FlotillaColors.accentContent.opacity(0.85) : FlotillaColors.textTertiary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 16)
            .background(
                onAccent ? Color.white.opacity(0.18) : FlotillaColors.surfaceElevated,
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(onAccent ? .clear : FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
            }
    }
}

/// Small uppercase label that names a group of controls.
struct LauncherEyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(FlotillaTypography.caption3.weight(.semibold))
            .tracking(FlotillaTypography.Tracking.loose2)
            .foregroundStyle(FlotillaColors.textTertiary)
    }
}

// MARK: - Goal field

/// The objective field uses `@` project and `/` agent searches to open a
/// results list beneath it. Return launches and opens, ⌥-Return inserts a
/// newline, Escape cancels
/// (or first closes an open search).
struct LauncherGoalField: View {
    @Bindable var draft: SessionDraft
    let actions: SessionLauncherActions
    var placeholder = "Describe the outcome…   @ project   / agent"
    var fontSize: CGFloat = 18
    var lines: ClosedRange<Int> = 1...4

    @State private var triggers = LauncherTriggers()
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            TextField(placeholder, text: $draft.goal, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: fontSize, weight: .regular))
                .lineLimit(lines)
                .focused($isFocused)
                .autocorrectionDisabled()
                .textContentType(nil)
                .onKeyPress { press in handle(press) }
                .onChange(of: draft.goal) { _, goal in
                    triggers.sync(goal: goal)
                    draft.syncModeFromGoal()
                }
                .onAppear { isFocused = true }
                .accessibilityIdentifier("CreateSession.GoalField")

            if triggers.isPicking {
                LauncherTriggerResults(triggers: triggers, draft: draft)
            }
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let result = triggers.handle(press, draft: draft)
        if result == .handled { return .handled }
        switch press.key {
        case .return:
            if press.modifiers.contains(.option) { return .ignored }
            if press.modifiers.contains([.command, .shift]) {
                if draft.canLaunch { actions.launch(false) }
                return .handled
            }
            if draft.canLaunch { actions.launch(true) }
            return .handled
        case .escape:
            actions.cancel()
            return .handled
        default:
            return .ignored
        }
    }
}

// MARK: - Agent

/// All four agents visible at once, each with its name — the current bar's
/// bare logos save width but make you hover to learn which is which.
struct LauncherAgentSegments: View {
    @Bindable var draft: SessionDraft
    var showsNames = true
    var fillsWidth = false

    var body: some View {
        HStack(spacing: FlotillaSpacing.xSmall) {
            ForEach(AgentKind.allCases) { kind in
                let isSelected = kind == draft.agent
                Button {
                    draft.selectAgent(kind)
                } label: {
                    HStack(spacing: 6) {
                        ProviderLogo(agent: kind)
                            .frame(width: 15, height: 15)
                        if showsNames {
                            Text(kind.displayName)
                                .font(FlotillaTypography.caption.weight(isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? FlotillaColors.textPrimary : FlotillaColors.textSecondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .padding(.horizontal, showsNames ? 10 : 7)
                    .frame(maxWidth: fillsWidth ? .infinity : nil)
                    .frame(height: 28)
                    .background(
                        isSelected ? FlotillaColors.accent.opacity(FlotillaStateOpacity.selected) : FlotillaColors.surfaceElevated.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: FlotillaRadius.control + 1, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: FlotillaRadius.control + 1, style: .continuous)
                            .strokeBorder(
                                isSelected ? FlotillaColors.accent.opacity(0.7) : FlotillaColors.separator,
                                lineWidth: FlotillaBorderWidth.hairline
                            )
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(kind.displayName)
                .accessibilityIdentifier("CreateSession.Agent.\(kind.rawValue)")
                .accessibilityLabel(kind.displayName)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }
}

/// Model and effort as a pair — the effort picker stays mounted and hides
/// itself (see `EffortLevelPicker.isVisible`).
struct LauncherModelControls: View {
    @Bindable var draft: SessionDraft
    let coordinator: AntigravityModelEffortCoordinator

    var body: some View {
        HStack(spacing: FlotillaSpacing.small) {
            ModelPickerView(
                agent: draft.agent,
                openCodeSubscription: draft.openCodeSubscription,
                model: $draft.model,
                effort: coordinator.currentEffort(for: draft)
            )
            .fixedSize()
            .accessibilityIdentifier("CreateSession.ModelField")
            EffortLevelPicker(
                agent: draft.agent,
                model: draft.model,
                effort: coordinator.effortBinding(for: draft),
                accessibilityIdentifier: "CreateSession.EffortPicker",
                isVisible: coordinator.supportsEffort(for: draft)
            )
        }
    }
}

// MARK: - Isolation

/// Checkout vs. worktree as a labeled segmented control, with room for the
/// words instead of cramming both into a caption-sized capsule.
struct LauncherIsolationPicker: View {
    @Bindable var draft: SessionDraft
    var fillsWidth = false

    var body: some View {
        HStack(spacing: 2) {
            segment(title: "Checkout", isWorktree: false, identifier: "CreateSession.Checkout.Main")
            segment(title: "Worktree", isWorktree: true, identifier: "CreateSession.Checkout.Worktree")
        }
        .padding(2)
        .background(FlotillaColors.surfaceElevated.opacity(0.7), in: RoundedRectangle(cornerRadius: FlotillaRadius.control + 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.control + 2, style: .continuous)
                .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
        }
        .disabled(!draft.supportsWorktree)
        .opacity(draft.supportsWorktree ? 1 : FlotillaStateOpacity.disabled)
        .help(draft.supportsWorktree ? "Where the agent works" : "General sessions have no checkout to isolate")
    }

    private func segment(title: String, isWorktree: Bool, identifier: String) -> some View {
        let isActive = draft.supportsWorktree && draft.createWorktree == isWorktree
        return Button {
            draft.createWorktree = isWorktree
        } label: {
            HStack(spacing: 5) {
                if isWorktree {
                    GitBranchIcon(size: FlotillaIconSize.xSmall)
                } else {
                    Image(systemName: "shippingbox")
                        .font(.system(size: FlotillaIconSize.xSmall))
                }
                Text(title)
                    .font(FlotillaTypography.caption.weight(.medium))
            }
            .foregroundStyle(isActive ? FlotillaColors.accentContent : FlotillaColors.textSecondary)
            .padding(.horizontal, 10)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(height: 24)
            .background(isActive ? FlotillaColors.accent : .clear, in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

// MARK: - Project

/// A searchable project list: general session, recents, "Choose folder…".
/// Shown inline by the rail design and inside a popover by the others.
struct LauncherProjectList: View {
    @Bindable var draft: SessionDraft
    var showsFilter = true
    var onPick: () -> Void = {}
    /// A popover needs to close before presenting an `NSOpenPanel`; callers
    /// with that presentation requirement provide their own sequencing.
    var onChooseFolder: (() -> Void)?

    @State private var query = ""
    @State private var hoveredChoiceID: String?
    @State private var isChooseFolderHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showsFilter {
                HStack(spacing: FlotillaSpacing.small) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: FlotillaIconSize.xSmall, weight: .medium))
                        .foregroundStyle(FlotillaColors.textTertiary)
                    TextField("Filter projects", text: $query)
                        .textFieldStyle(.plain)
                        .font(FlotillaTypography.caption)
                        .autocorrectionDisabled()
                        .textContentType(nil)
                        .accessibilityIdentifier("CreateSession.ProjectFilter")
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(FlotillaColors.surfaceElevated.opacity(0.6), in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
                .padding(.bottom, FlotillaSpacing.xSmall)
            }

            ForEach(draft.filteredChoices(query: query)) { choice in
                row(choice)
            }

            Button {
                if let onChooseFolder {
                    onChooseFolder()
                } else {
                    onPick()
                    draft.chooseFolderFromPanel()
                }
            } label: {
                HStack(spacing: FlotillaSpacing.small) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: FlotillaIconSize.small))
                        .frame(width: FlotillaIconSize.medium)
                    Text("Choose folder…")
                        .font(FlotillaTypography.callout)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(FlotillaColors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                        .fill(isChooseFolderHovered ? FlotillaColors.accent.opacity(0.12) : .clear)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isChooseFolderHovered = $0 }
            .accessibilityIdentifier("CreateSession.ChooseFolderButton")
        }
    }

    private func row(_ choice: ProjectChoice) -> some View {
        let isSelected = choice == draft.projectChoice
        return Button {
            draft.projectChoice = choice
            onPick()
        } label: {
            HStack(spacing: FlotillaSpacing.small) {
                Image(systemName: choice.symbolName)
                    .font(.system(size: FlotillaIconSize.small))
                    .foregroundStyle(isSelected ? FlotillaColors.accent : FlotillaColors.textTertiary)
                    .frame(width: FlotillaIconSize.medium)
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .lineLimit(1)
                    Text(choice.displayPath ?? "No repository · scratch folder")
                        .font(.system(size: 11))
                        .foregroundStyle(FlotillaColors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
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
                    .fill(hoveredChoiceID == choice.id ? FlotillaColors.accent.opacity(0.12) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hoveredChoiceID = choice.id
            } else if hoveredChoiceID == choice.id {
                hoveredChoiceID = nil
            }
        }
        .accessibilityIdentifier(
            choice.isGeneral ? "CreateSession.Source.General" : "CreateSession.Project.\(choice.displayName)"
        )
    }
}

/// Esc · Launch & Stay · Launch — real buttons with their shortcuts shown.
struct LauncherLaunchButtons: View {
    @Bindable var draft: SessionDraft
    let actions: SessionLauncherActions
    var showsCancel = true

    var body: some View {
        HStack(spacing: FlotillaSpacing.small) {
            if showsCancel {
                Button { actions.cancel() } label: {
                    HStack(spacing: 5) {
                        Text("Cancel")
                        LauncherKeycap("esc")
                    }
                    .font(FlotillaTypography.caption.weight(.medium))
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("CreateSession.CancelButton")
                .accessibilityLabel("Cancel")
            }

            Button { actions.launch(false) } label: {
                HStack(spacing: 6) {
                    Text("Launch & Stay")
                    LauncherKeycap("⇧⌘↩")
                }
                .font(FlotillaTypography.caption.weight(.medium))
                .foregroundStyle(FlotillaColors.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(FlotillaColors.surfaceElevated, in: RoundedRectangle(cornerRadius: FlotillaRadius.control + 1, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: FlotillaRadius.control + 1, style: .continuous)
                        .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!draft.canLaunch)
            .accessibilityIdentifier("CreateSession.BackgroundButton")

            Button { actions.launch(true) } label: {
                HStack(spacing: 6) {
                    if draft.isCreating {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(FlotillaColors.accentContent)
                            .accessibilityIdentifier("CreateSession.ProgressIndicator")
                    }
                    Text("Launch")
                    LauncherKeycap("↩", onAccent: true)
                }
                .font(FlotillaTypography.caption.weight(.semibold))
                .foregroundStyle(FlotillaColors.accentContent)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(FlotillaColors.accent, in: RoundedRectangle(cornerRadius: FlotillaRadius.control + 1, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!draft.canLaunch)
            .opacity(draft.canLaunch ? 1 : FlotillaStateOpacity.disabled)
            .accessibilityIdentifier("CreateSession.CreateButton")
            .accessibilityLabel("Launch & Open")
        }
        // The buttons keep their words; the preview beside them truncates.
        .fixedSize()
    }
}

/// ⌘↩ / ⇧⌘↩ / Esc, reachable regardless of which control has focus.
struct LauncherHiddenShortcuts: View {
    let actions: SessionLauncherActions

    var body: some View {
        Group {
            Button("") { actions.launch(true) }
                .keyboardShortcut(.return, modifiers: .command)
            Button("") { actions.launch(false) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("") { actions.cancel() }
                .keyboardShortcut(.cancelAction)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

/// Error banner shared by all candidates.
struct LauncherErrorBanner: View {
    @Bindable var store: AppStore

    var body: some View {
        if let error = store.lastCreationError {
            FlotillaBanner.error(error) { store.lastCreationError = nil }
        }
    }
}
