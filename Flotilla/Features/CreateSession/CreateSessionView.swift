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
/// Renders `CommandBarDesign` — a Spotlight-style single field. This started
/// as one of four candidate designs compared side by side via a temporary
/// ⌘1–⌘4 switcher; Command Bar won for this context because opening the window
/// is already a deliberate keyboard interruption, which suits a fast
/// type-and-launch flow. The card-grid alternative (`LaunchpadDesign`) went to
/// the home dashboard instead, where browsing recent projects fits an
/// always-visible, ambient composer better. Both designs share `SessionDraft`
/// and `SessionLaunchPreview`, so neither can drift from what a launch
/// actually does.
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

    init(
        store: AppStore,
        createWorktreeByDefault: Bool = true,
        fetchBeforeCreatingWorktree: Bool = false,
        initialProject: Project? = nil,
        initialGoal: String = "",
        didCreateSession: @escaping (UUID) -> Void = { _ in },
        openCodeSubscription: OpenCodeSubscription = .none,
        defaultAgent: AgentKind = .claudeCode,
        onDismiss: (() -> Void)? = nil
    ) {
        self.store = store
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
        // card's rounded corners. `CommandBarDesign`'s own `.glassEffect`
        // shape is the entire visible surface now.
        CommandBarDesign(draft: draft, store: store, actions: actions)
            .frame(width: 660)
            .overlay { dropHighlight }
            .dropDestination(for: URL.self) { urls, _ in
                receiveDrop(urls)
            } isTargeted: { targeted in
                isTargetedForDrop = targeted
            }
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
            guard let id = await draft.launch() else { return }
            if opensSession { didCreateSession(id) }
            dismiss()
        }
    }
}

/// The two things `CommandBarDesign` needs to be able to do to its host.
struct SessionLauncherActions {
    /// `opensSession: false` creates the session without navigating to it.
    let launch: (Bool) -> Void
    let cancel: () -> Void
}
