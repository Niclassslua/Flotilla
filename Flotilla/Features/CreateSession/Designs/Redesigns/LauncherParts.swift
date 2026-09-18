import SwiftUI
import SessionKit
import AgentKit
import DesignSystem
import SettingsKit

extension LauncherStyle {
    /// Overlay width. The classic bar's 660pt is what makes it cramped; each
    /// newer style takes the room its layout actually needs.
    var launcherWidth: CGFloat {
        switch self {
        case .classic: 660
        case .controlDeck: 720
        case .projectRail: 840
        case .tiles: 740
        case .sentence: 700
        }
    }

    /// One line for the Settings picker and the in-launcher style menu.
    var summary: String {
        switch self {
        case .classic: "One Spotlight-style line; everything else in a chip strip."
        case .controlDeck: "Goal on top, then a labeled row each for agent, model, and workspace."
        case .projectRail: "A searchable project list beside a large goal editor."
        case .tiles: "Workspace, Agent, and Launch as three cards under the goal."
        case .sentence: "Settings read as one sentence of inline controls, with the literal command below."
        }
    }
}

// MARK: - Surface

private struct LauncherSnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set while rendering offscreen for comparison screenshots. Liquid Glass
    /// samples what is behind the window, which an offscreen bitmap has none
    /// of, so the surface falls back to an opaque fill there.
    var launcherSnapshot: Bool {
        get { self[LauncherSnapshotKey.self] }
        set { self[LauncherSnapshotKey.self] = newValue }
    }
}

private struct LauncherSurface: ViewModifier {
    @Environment(\.launcherSnapshot) private var isSnapshot

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: FlotillaRadius.modal, style: .continuous)
        content
            .background {
                if isSnapshot { shape.fill(FlotillaColors.surface) }
            }
            .glassEffect(.regular, in: shape)
            .overlay { shape.strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline) }
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

/// The objective field every newer style shares, with the Command Bar's
/// `@` project and `/` agent searches opening a results list beneath it.
/// Return launches and opens, ⇧/⌥-Return inserts a newline, Escape cancels
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
            if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
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

    @State private var query = ""

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
                        .accessibilityIdentifier("CreateSession.ProjectFilter")
                }
                .padding(.horizontal, FlotillaSpacing.small)
                .frame(height: 26)
                .background(FlotillaColors.surfaceElevated.opacity(0.6), in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
                .padding(.bottom, FlotillaSpacing.xSmall)
            }

            ForEach(draft.filteredChoices(query: query)) { choice in
                row(choice)
            }

            Button {
                onPick()
                draft.chooseFolderFromPanel()
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
                .padding(.horizontal, FlotillaSpacing.small)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
                        .font(FlotillaTypography.callout.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .lineLimit(1)
                    Text(choice.displayPath ?? "No repository · scratch folder")
                        .font(FlotillaTypography.caption3)
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(FlotillaTypography.caption2.weight(.bold))
                        .foregroundStyle(FlotillaColors.accent)
                }
            }
            .padding(.horizontal, FlotillaSpacing.small)
            .padding(.vertical, 6)
            .background(
                isSelected ? FlotillaColors.accent.opacity(FlotillaStateOpacity.hover) : .clear,
                in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(
            choice.isGeneral ? "CreateSession.Source.General" : "CreateSession.Project.\(choice.displayName)"
        )
    }
}

/// A trigger that opens `LauncherProjectList` in the launcher's own view
/// hierarchy. The New Session launcher is already an in-window overlay; using
/// an AppKit popover below it gives macOS's text-completion remote view two
/// competing containing windows and can raise an `NSInternalInconsistencyException`
/// when a project row is chosen. Keeping this list in-window also makes its
/// lifetime match the launcher that owns the draft.
struct LauncherProjectButton<Label: View>: View {
    @Bindable var draft: SessionDraft
    @ViewBuilder var label: () -> Label
    var presentationChanged: (Bool) -> Void = { _ in }

    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: { label() }
            .buttonStyle(.plain)
            .onChange(of: isPresented) { _, isPresented in
                presentationChanged(isPresented)
            }
            .overlay(alignment: .bottomLeading) {
                if isPresented {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .overlay(alignment: .topLeading) {
                            projectList
                        }
                }
            }
            .zIndex(isPresented ? 1 : 0)
            .help("Choose the workspace")
            .accessibilityIdentifier("CreateSession.ProjectPicker")
            .accessibilityValue(draft.projectChoice.displayName)
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Workspace")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(FlotillaColors.textTertiary)
                .textCase(.uppercase)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 4)

            LauncherProjectList(draft: draft) { isPresented = false }
                .padding(.horizontal, FlotillaSpacing.small)
        }
            .padding(.bottom, FlotillaSpacing.small)
            .frame(width: 320)
            .background(
                FlotillaColors.surfaceElevated,
                in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                    .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
            }
            .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
    }
}

// MARK: - Launch

/// What will run and where: branch (or directory) and the argv.
struct LauncherPreviewText: View {
    let preview: SessionLaunchPreview

    var body: some View {
        HStack(spacing: FlotillaSpacing.small) {
            if preview.isWorktree {
                GitBranchIcon(size: FlotillaIconSize.xSmall)
                    .foregroundStyle(FlotillaColors.statusReady)
            } else {
                Image(systemName: "shippingbox")
                    .font(.system(size: FlotillaIconSize.xSmall))
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
            Text(preview.displayBranch ?? preview.displayDirectory)
                .foregroundStyle(FlotillaColors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("·").foregroundStyle(FlotillaColors.textTertiary)
            Text(preview.command)
                .foregroundStyle(FlotillaColors.textTertiary)
                .lineLimit(1)
            if let warning = preview.sharedCheckoutWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(FlotillaColors.warning)
                    .help(warning)
                    .accessibilityLabel("Shared checkout")
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CreateSession.LaunchSummary")
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
