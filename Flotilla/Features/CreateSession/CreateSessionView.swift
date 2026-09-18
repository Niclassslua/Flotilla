import SwiftUI
import AppKit
import SessionKit
import AgentKit
import DesignSystem
import SettingsKit

/// The New Session window: a modal, keyboard-driven launcher, opened from the
/// sidebar's New Session button, the command palette, ⌘N, or a "fix this
/// commit" shortcut.
///
/// Renders the layout chosen in Settings ▸ Sessions (`LauncherStyle`): the
/// original Spotlight-style `CommandBarDesign`, or one of four roomier styles
/// built on it — Control Deck, Project Rail, Tiles, Sentence. ⌥⌘1–⌥⌘5 switch
/// styles live from inside the window and persist the choice. The card-grid
/// `LaunchpadDesign` lives on the home dashboard instead. Every style shares
/// `SessionDraft` and `SessionLaunchPreview`, so none can drift from what a
/// launch actually does, and switching keeps whatever you've typed.
struct CreateSessionView: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var environmentDismiss

    let didCreateSession: (UUID) -> Void
    /// Overrides the environment dismiss action. `FlotillaShell` presents this
    /// view as an in-window overlay rather than a real `.sheet` (so it can be
    /// dismissed by clicking outside it, which a genuine AppKit sheet can
    /// never support) — an overlay gets no environment dismiss action from
    /// SwiftUI, so that call site must supply this explicitly.
    /// `ProjectDetailView` still presents through a real `.sheet(isPresented:)`
    /// and leaves this `nil`, relying on the environment as before.
    let onDismiss: (() -> Void)?

    @State private var draft: SessionDraft
    @State private var isTargetedForDrop = false
    /// Bound to the setting so a live switch here is the same choice as the
    /// Settings picker, not a separate per-window override.
    @Binding var style: LauncherStyle

    init(
        store: AppStore,
        createWorktreeByDefault: Bool = true,
        fetchBeforeCreatingWorktree: Bool = false,
        initialProject: Project? = nil,
        initialGoal: String = "",
        didCreateSession: @escaping (UUID) -> Void = { _ in },
        openCodeSubscription: OpenCodeSubscription = .none,
        defaultAgent: AgentKind = .claudeCode,
        style: Binding<LauncherStyle> = .constant(.classic),
        onDismiss: (() -> Void)? = nil
    ) {
        self.store = store
        self._style = style
        self.didCreateSession = didCreateSession
        self.onDismiss = onDismiss
        _draft = State(initialValue: SessionDraft(
            store: store,
            initialProject: initialProject,
            initialGoal: initialGoal,
            createWorktreeByDefault: createWorktreeByDefault,
            fetchBeforeCreatingWorktree: fetchBeforeCreatingWorktree,
            defaultAgent: defaultAgent,
            openCodeSubscription: openCodeSubscription
        ))
    }

    private func dismiss() {
        if let onDismiss { onDismiss() } else { environmentDismiss() }
    }

    var body: some View {
        // No opaque background here: the previous rectangular canvas fill
        // behind the glass card was visible as a "box" peeking past the
        // card's rounded corners. The design's own `.glassEffect` shape is
        // the entire visible surface now.
        LauncherStyleBody(style: style, draft: draft, store: store, actions: actions)
            .frame(width: style.launcherWidth)
            .overlay { dropHighlight }
            .overlay(alignment: .topTrailing) { styleMenu }
            .background { styleShortcuts }
            .dropDestination(for: URL.self) { urls, _ in
                receiveDrop(urls)
            } isTargeted: { targeted in
                isTargetedForDrop = targeted
            }
            .animation(FlotillaMotion.snappy.curve, value: style)
    }

    // MARK: - Style switching

    /// Sits just above the panel's top-right corner: visible enough to find,
    /// outside the panel so it never competes with the launcher's own controls.
    private var styleMenu: some View {
        Menu {
            Picker("Layout", selection: $style) {
                ForEach(LauncherStyle.allCases) { candidate in
                    Text(candidate.displayName).tag(candidate)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.3.group")
                Text(style.displayName)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(FlotillaTypography.caption2.weight(.medium))
            .foregroundStyle(FlotillaColors.textSecondary)
            .padding(.horizontal, FlotillaSpacing.small)
            .padding(.vertical, 3)
            .background(FlotillaColors.surfaceElevated, in: Capsule())
            .overlay(Capsule().strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .offset(y: -30)
        .help("New Session layout (⌥⌘1–⌥⌘5)")
        .accessibilityIdentifier("CreateSession.LayoutMenu")
        .accessibilityLabel("New Session layout")
        .accessibilityValue(style.displayName)
    }

    private var styleShortcuts: some View {
        Group {
            ForEach(Array(LauncherStyle.allCases.enumerated()), id: \.element) { index, candidate in
                Button("") { style = candidate }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var actions: SessionLauncherActions {
        SessionLauncherActions(
            launch: { opensSession in launch(opensSession: opensSession) },
            cancel: { dismiss() }
        )
    }

    // MARK: - Drop

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: FlotillaRadius.modal, style: .continuous)
            .strokeBorder(FlotillaColors.accent, lineWidth: FlotillaBorderWidth.medium)
            .opacity(isTargetedForDrop ? 1 : 0)
            .animation(FlotillaMotion.fast.curve, value: isTargetedForDrop)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Only directories are meaningful here — a dropped file would resolve to a
    /// working directory the agent cannot run in.
    private func receiveDrop(_ urls: [URL]) -> Bool {
        guard let folder = urls.first(where: { url in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }) else { return false }
        draft.select(folder: folder)
        return true
    }

    // MARK: - Launch

    private func launch(opensSession: Bool) {
        Task {
            store.lastCreationError = nil
            guard let id = await draft.launch(opensSession: opensSession) else { return }
            if opensSession { didCreateSession(id) }
            dismiss()
        }
    }
}

/// Renders one launcher style. Shared by the overlay and the Debug snapshot
/// renderer so both show exactly the same view.
struct LauncherStyleBody: View {
    let style: LauncherStyle
    let draft: SessionDraft
    let store: AppStore
    let actions: SessionLauncherActions

    var body: some View {
        switch style {
        case .classic: CommandBarDesign(draft: draft, store: store, actions: actions)
        case .controlDeck: ControlDeckDesign(draft: draft, store: store, actions: actions)
        case .projectRail: ProjectRailDesign(draft: draft, store: store, actions: actions)
        case .tiles: TilesDesign(draft: draft, store: store, actions: actions)
        case .sentence: SentenceDesign(draft: draft, store: store, actions: actions)
        }
    }
}

/// The two things every launcher style needs to be able to do to its host.
struct SessionLauncherActions {
    /// `opensSession: false` creates the session without navigating to it.
    let launch: (Bool) -> Void
    let cancel: () -> Void
}
