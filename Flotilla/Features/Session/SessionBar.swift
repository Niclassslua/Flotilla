import SwiftUI
import SessionKit
import DesignSystem

/// What a session bar can do, bundled so the two variants take one parameter
/// instead of repeating six closures — the same shape as `SessionTileActions`.
struct SessionBarActions {
    var onRename: (String) -> Void = { _ in }
    var onToggleGitSidebar: () -> Void = {}
    var onBrowseFiles: () -> Void = {}
    var onReviewChanges: () -> Void = {}
    var onFocus: () -> Void = {}
    var onRemoveFromGrid: () -> Void = {}
}

/// The bar that states what one session *is*, and what you can do to it.
///
/// **One type, two variants** — the codebase's existing convention for a
/// component that appears at two densities (see `SessionCard`'s four). Both
/// answer the same question in the same order, so a session reads the same
/// way whether it fills the window or sits in a tile; only the trailing
/// actions and the amount of metadata differ.
///
/// - `.focus` — under the window toolbar when one session fills the detail
///   column. This is now the *only* place a focused session's identity is
///   stated: the window subtitle used to carry it, competing with the title
///   two points above it.
/// - `.tile` — the grid tile's 28pt chrome bar. Height is unchanged from the
///   header it replaces; the grid exists to show terminals, so the extra
///   fields have to come out of truncation priority, not out of the terminal.
struct SessionBar: View {
    enum Variant {
        case focus
        case tile

        var height: CGFloat {
            switch self {
            case .focus: 34
            case .tile: 28
            }
        }

        var font: Font {
            switch self {
            case .focus: .system(size: 12, weight: .medium)
            case .tile: .caption.weight(.medium)
            }
        }
    }

    let session: Session
    let store: AppStore
    var variant: Variant = .focus
    var actions = SessionBarActions()

    /// `nil` unless the title is being edited — holding the draft here rather
    /// than in a permanent `@State String` means the field can never show a
    /// stale title after the agent renames the session underneath it.
    @State private var draftTitle: String?
    @FocusState private var isEditingTitle: Bool

    // MARK: - Derived identity

    /// General is a real group, not the absence of one, so an unassigned
    /// session names it rather than rendering a bare title with a dangling
    /// separator.
    private var projectName: String {
        store.project(for: session)?.name ?? "General"
    }

    private var branchName: String? { session.worktree?.branchName }

    /// The worktree's own directory name. With no worktree the agent is
    /// working in the checkout itself, and naming that directory is more use
    /// than naming nothing — the same fallback the window subtitle used.
    private var worktreeName: String {
        (session.worktree?.worktreePath ?? session.workingDirectory).lastPathComponent
    }

    /// Both project-owned panels need a project to open into. An unassigned
    /// session has none, which is ordinary rather than exceptional — saying
    /// why beats a button that accepts the click and does nothing.
    private var hasProject: Bool { session.projectID != nil }

    var body: some View {
        HStack(spacing: FlotillaSpacing.small) {
            identityLockup
            Spacer(minLength: FlotillaSpacing.small)
            trailingActions
        }
        .padding(.horizontal, variant == .focus ? FlotillaSpacing.medium : FlotillaSpacing.small)
        .frame(height: variant.height)
        .background(FlotillaColors.surface)
        .accessibilityIdentifier(AXID.sessionBar(session.title))
    }

    // MARK: - Leading

    /// Truncation priority, highest first: the session's own name, the
    /// project it belongs to, its diff stat, its branch, its worktree. A
    /// four-column tile cannot hold all five, and the first thing worth
    /// losing is the directory name that the branch name already implies.
    private var identityLockup: some View {
        HStack(spacing: 6) {
            StatusBadge(session.status, waitingReason: session.waitingReason, variant: .compact)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(StatusPresentation.label(for: session.status, waitingReason: session.waitingReason))
                .accessibilityIdentifier(
                    variant == .tile
                        ? AXID.gridTileStatus(session.title)
                        : AXID.sessionBarStatus(session.title)
                )

            titleLockup
                .layoutPriority(3)

            if variant == .tile {
                SessionDiffStatView(session: session, diffStatStore: store.diffStatStore)
                    .layoutPriority(1)
            }

            if let branchName {
                metaLabel(branchName, systemImage: "arrow.triangle.branch")
                    .accessibilityIdentifier(AXID.sessionBarBranch(session.title))
                    .layoutPriority(-1)
            }

            metaLabel(worktreeName, systemImage: "folder")
                .accessibilityIdentifier(AXID.sessionBarWorktree(session.title))
                .layoutPriority(-2)
        }
    }

    /// `project / name`, where only the name half is editable. The project
    /// is context, not a field: it changes by moving the session, not by
    /// typing. It stays put while the name is being edited, so the row does
    /// not reflow around the field and you can still see what you are
    /// renaming *within*.
    private var titleLockup: some View {
        HStack(spacing: 4) {
            Text(projectName)
                .foregroundStyle(FlotillaColors.textTertiary)
                .lineLimit(1)
                .layoutPriority(1)
            Text("/")
                .foregroundStyle(FlotillaColors.textTertiary.opacity(0.6))
            editableName
                .layoutPriority(2)
        }
        .font(variant.font)
    }

    @ViewBuilder
    private var editableName: some View {
        if let draftTitle {
            TextField("Session name", text: Binding(
                get: { draftTitle },
                set: { self.draftTitle = $0 }
            ))
            .textFieldStyle(.plain)
            .focused($isEditingTitle)
            .frame(minWidth: 80, idealWidth: 160)
            // Focus is claimed here rather than in `beginRename`: a
            // `@FocusState` binding set while the field is still absent from
            // the hierarchy is simply dropped, leaving an editable-looking
            // field that swallows the first keystroke.
            .onAppear { isEditingTitle = true }
            .onSubmit(commitRename)
            .onExitCommand { self.draftTitle = nil }
            // Clicking away is a commit, not a discard: the field is inline
            // in a bar with no visible Done button, so losing focus without
            // saving would silently throw the edit away.
            .onChange(of: isEditingTitle) { _, focused in
                if !focused { commitRename() }
            }
            .accessibilityIdentifier(AXID.sessionBarTitleField(session.title))
        } else {
            Button(action: beginRename) {
                Text(session.title)
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Rename this session")
            .accessibilityIdentifier(AXID.sessionBarTitle(session.title))
        }
    }

    private func metaLabel(_ text: String, systemImage: String) -> some View {
        Label {
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: systemImage)
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(FlotillaColors.textSecondary)
    }

    // MARK: - Trailing

    @ViewBuilder
    private var trailingActions: some View {
        switch variant {
        case .focus:
            focusActions
        case .tile:
            tileActions
        }
    }

    private var focusActions: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Text(SessionElapsed.since(session.createdAt))
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(FlotillaColors.textTertiary)
                .help("Session age")
                .accessibilityLabel("Session age")
                .accessibilityIdentifier(AXID.sessionBarAge(session.title))

            // Renders disabled on purpose: there is no git sidebar to show
            // yet. A button that accepted the click and did nothing would be
            // indistinguishable from one that is broken.
            barButton("sidebar.right", help: "Git sidebar (not available yet)", action: actions.onToggleGitSidebar)
                .disabled(true)
                .accessibilityIdentifier(AXID.sessionBarGitSidebarToggle.rawValue)

            barButton(
                "folder",
                help: hasProject
                    ? "Browse and edit files"
                    : "This session is not assigned to a project, so there is no file tree to browse.",
                action: actions.onBrowseFiles
            )
            .disabled(!hasProject)
            .accessibilityIdentifier(AXID.toolbarOpenProjectFiles.rawValue)

            barButton(
                "arrow.triangle.branch",
                help: hasProject
                    ? "Review this session's changes"
                    : "This session is not assigned to a project, so there is no repository workspace to open.",
                action: actions.onReviewChanges
            )
            .disabled(!hasProject)
            .accessibilityIdentifier(AXID.toolbarOpenProjectGit.rawValue)
        }
    }

    private var tileActions: some View {
        HStack(spacing: 2) {
            barButton(
                "arrow.up.left.and.arrow.down.right",
                help: "Focus on this session",
                action: actions.onFocus
            )
            .accessibilityIdentifier(AXID.gridTileFocusButton(session.title))

            barButton("minus.circle", help: "Remove from grid", action: actions.onRemoveFromGrid)
                .accessibilityIdentifier(AXID.gridTileRemoveButton(session.title))
        }
    }

    private func barButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: variant == .focus ? 11 : 10, weight: .medium))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Rename

    private func beginRename() {
        draftTitle = session.title
    }

    /// Trimming and the empty-title guard live in
    /// `AppStore.syncDiscoveredTitle`, which this ultimately calls, so an
    /// all-whitespace entry reverts instead of blanking the session.
    private func commitRename() {
        guard let draftTitle else { return }
        self.draftTitle = nil
        isEditingTitle = false
        guard draftTitle != session.title else { return }
        actions.onRename(draftTitle)
    }
}
