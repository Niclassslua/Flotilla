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
/// Tiles is the single focused layout for the New Session window, and this
/// window is the only place sessions are created — Home no longer has a
/// composer of its own.
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
    private let opensIssuePicker: Bool
    private let initialIssueNumber: Int?
    init(
        store: AppStore,
        createWorktreeByDefault: Bool = true,
        fetchBeforeCreatingWorktree: Bool = false,
        initialProject: Project? = nil,
        initialGoal: String = "",
        didCreateSession: @escaping (UUID) -> Void = { _ in },
        openCodeSubscription: OpenCodeSubscription = .none,
        defaultAgent: AgentKind = .claudeCode,
        opensIssuePicker: Bool = false,
        initialIssueNumber: Int? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.store = store
        self.opensIssuePicker = opensIssuePicker
        self.initialIssueNumber = initialIssueNumber
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
        TilesDesign(draft: draft, store: store, actions: actions, opensIssuePicker: opensIssuePicker, initialIssueNumber: initialIssueNumber)
            .frame(width: 740)
            .overlay { dropHighlight }
            .background { ImagePasteCatcher { draft.attach($0) } }
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

    /// A dropped folder becomes the workspace and dropped images are attached
    /// to the goal. Any other file is refused — it would resolve to a working
    /// directory the agent cannot run in.
    private func receiveDrop(_ urls: [URL]) -> Bool {
        let folder = urls.first(where: { url in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        })
        let images = urls.compactMap(SessionAttachment.init(fileURL:))
        if let folder { draft.select(folder: folder) }
        draft.attach(images)
        return folder != nil || !images.isEmpty
    }

    // MARK: - Launch

    private func launch(opensSession: Bool) {
        Task {
            store.lastCreationError = nil
            guard let id = await draft.launch(opensSession: opensSession) else { return }
            if opensSession {
                didCreateSession(id)
                dismiss()
            } else {
                draft.clearGoal()
            }
        }
    }
}

/// The two things the New Session tiles need to be able to do to their host.
struct SessionLauncherActions {
    /// `opensSession: false` creates the session without navigating to it.
    let launch: (Bool) -> Void
    let cancel: () -> Void
}
