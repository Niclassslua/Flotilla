import SwiftUI
import SessionKit
import DesignSystem

/// What a session bar can do, bundled so the two variants take one parameter
/// instead of repeating six closures — the same shape as `SessionTileActions`.
struct SessionBarActions {
    var onRename: (String) -> Void = { _ in }
    var onToggleGitSidebar: () -> Void = {}
    var onBrowseFiles: () -> Void = {}
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

        /// Trailing padding, measured to the chip's edge rather than to the
        /// glyph — see `body`.
        var trailingInset: CGFloat {
            switch self {
            case .focus: FlotillaSpacing.small
            case .tile: FlotillaSpacing.xSmall
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
        // Spacing 0 on purpose: the `Spacer` is the only gap between the
        // identity and the actions. With the stack also spacing its children
        // the two combined to a 24pt minimum, a quarter of a four-column
        // tile's bar spent on nothing while the branch and worktree beside it
        // truncated to stubs.
        HStack(spacing: 0) {
            identityLockup
            Spacer(minLength: FlotillaSpacing.medium)
            trailingActions
        }
        .padding(.leading, variant == .focus ? FlotillaSpacing.medium : FlotillaSpacing.small)
        // The action chips carry their own padding around the glyph, so the
        // trailing inset is smaller than the leading one to land the icons
        // the same optical distance from the edge as the status badge.
        .padding(.trailing, variant.trailingInset)
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
                metaBranchLabel(branchName)
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

    private func metaBranchLabel(_ text: String) -> some View {
        Label {
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            GitBranchIcon(size: 10)
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(FlotillaColors.textSecondary)
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

            // The two icons are one cluster, at the same 2pt as the tile's
            // pair: 8pt between chips that already carry their own margin
            // read as two separate controls that happened to land together.
            //
            // The sidebar toggle sits last, against the bar's trailing edge,
            // because that is the edge the sidebar itself opens from.
            HStack(spacing: 2) {
                barButton(
                    "folder",
                    help: hasProject
                        ? "Browse and edit files"
                        : "This session is not assigned to a project, so there is no file tree to browse.",
                    action: actions.onBrowseFiles
                )
                .disabled(!hasProject)
                .accessibilityLabel("Browse files")
                .accessibilityIdentifier(AXID.toolbarOpenProjectFiles.rawValue)

                barButton(
                    "sidebar.right",
                    help: hasProject
                        ? "Toggle Git sidebar"
                        : "This session is not assigned to a project, so there is no repository sidebar to show.",
                    action: actions.onToggleGitSidebar
                )
                .disabled(!hasProject)
                .accessibilityLabel("Git sidebar")
                .accessibilityIdentifier(AXID.sessionBarGitSidebarToggle.rawValue)
            }
        }
    }

    /// Spacing 2 rather than 0: the chips already reserve their own margin
    /// around each glyph, so a wider gap here would read as two unrelated
    /// buttons instead of one cluster.
    private var tileActions: some View {
        HStack(spacing: 2) {
            barButton(
                "arrow.up.left.and.arrow.down.right",
                help: "Focus on this session",
                action: actions.onFocus
            )
            .accessibilityLabel("Focus on this session")
            .accessibilityIdentifier(AXID.gridTileFocusButton(session.title))

            barButton("minus.circle", help: "Remove from grid", action: actions.onRemoveFromGrid)
                .accessibilityLabel("Remove from grid")
                .accessibilityIdentifier(AXID.gridTileRemoveButton(session.title))
        }
    }

    private func barButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        SessionBarIconButton(systemImage: systemImage, help: help, action: action)
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

// MARK: - Bar action chip

/// A bar action rendered as a hover-lit chip rather than a bare glyph.
///
/// The tile bar packs a status badge, `project / name`, a diff stat, a branch
/// and a worktree into 28pt, all of it small and grey. Two unadorned 10pt
/// icons at the trailing edge joined that texture instead of standing apart
/// from it, which is what made the corner read as clutter rather than as
/// controls. The chip gives the pair an edge of its own and gives the pointer
/// a 22pt square to land on, without costing the bar any height.
private struct SessionBarIconButton: View {
    var systemImage: String? = nil
    var isGitBranch: Bool = false
    let help: String
    let action: () -> Void

    /// Read from the environment rather than passed in, so a caller's
    /// `.disabled(true)` — the focus bar's git-sidebar toggle — reaches the
    /// chip's own colours instead of only greying the label.
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    private static let side: CGFloat = 22

    private var foreground: Color {
        guard isEnabled else { return FlotillaColors.textTertiary }
        return isHovering ? FlotillaColors.textPrimary : FlotillaColors.textSecondary
    }

    var body: some View {
        Button(action: action) {
            Group {
                if isGitBranch {
                    GitBranchIcon(size: 11)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(foreground)
            .frame(width: Self.side, height: Self.side)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        FlotillaColors.textPrimary
                            .opacity(isHovering ? FlotillaStateOpacity.hover : 0)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        // Guarded on `isEnabled` so a disabled control never lights up; the
        // pointer still gets the tooltip explaining why it is disabled.
        .onHover { isHovering = isEnabled && $0 }
        .withFlotillaMotion(.fast, value: isHovering)
    }
}
