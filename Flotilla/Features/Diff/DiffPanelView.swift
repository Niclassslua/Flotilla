import SwiftUI
import AppKit
import Observation
import SessionKit
import GitKit
import DesignSystem

@Observable
@MainActor
final class DiffPanelViewModel {
    let session: Session
    private let gitService: any GitServiceProtocol
    private let ghService: (any GhServiceProtocol)?
    /// Environment for commits made here, attributing them to the session
    /// whose checkout this is; empty when there is no such session.
    var commitEnvironment: (@MainActor () -> [String: String])?

    private(set) var snapshot = GitChangesSnapshot(
        status: GitStatus(entries: []),
        staged: [],
        unstaged: [],
        untracked: []
    )
    private(set) var isLoading = false
    private(set) var hasLoadedOnce = false
    private(set) var errorMessage: String?

    /// Separate from `errorMessage`: that one reflects the last *read*
    /// (`refresh`), this one the last *write* (stage/unstage/discard/
    /// commit/push/PR) — a failed commit shouldn't read as "changes failed
    /// to load" or vice versa.
    private(set) var actionErrorMessage: String?

    var commitMessage: String = ""
    private(set) var isCommitting = false
    private(set) var isPushing = false
    private(set) var isCreatingPR = false
    private(set) var lastPullRequestURL: URL?

    var isGhAvailable: Bool { ghService != nil }

    private var repoPath: URL {
        session.worktree?.worktreePath ?? session.workingDirectory
    }

    init(
        session: Session,
        gitService: any GitServiceProtocol,
        ghService: (any GhServiceProtocol)? = nil,
        commitEnvironment: (@MainActor () -> [String: String])? = nil
    ) {
        self.session = session
        self.gitService = gitService
        self.ghService = ghService
        self.commitEnvironment = commitEnvironment
    }

    func monitor() async {
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await refresh(showsSpinner: false)
        }
    }

    func refresh(showsSpinner: Bool = true) async {
        if showsSpinner { isLoading = true }
        defer {
            isLoading = false
            hasLoadedOnce = true
        }
        do {
            snapshot = try await gitService.changes(at: repoPath)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelMonitoring() {
        // Task will be cancelled by the parent
    }

    func stage(_ entry: FileDiff) async {
        await performWrite { try await gitService.stage(paths: [entry.path], at: repoPath) }
    }

    func unstage(_ entry: FileDiff) async {
        await performWrite { try await gitService.unstage(paths: [entry.path], at: repoPath) }
    }

    /// Irreversible — the caller must confirm with the user before calling
    /// this (see `DiffFileRow`'s discard confirmation dialog).
    func discard(_ entry: FileDiff) async {
        await performWrite { try await gitService.discard(paths: [entry.path], at: repoPath) }
    }

    /// Whole-section staging. One git invocation for the batch rather than one
    /// per file, so a section header button costs the same as a single row.
    func stage(_ entries: [FileDiff]) async {
        guard !entries.isEmpty else { return }
        await performWrite { try await gitService.stage(paths: entries.map(\.path), at: repoPath) }
    }

    func unstage(_ entries: [FileDiff]) async {
        guard !entries.isEmpty else { return }
        await performWrite { try await gitService.unstage(paths: entries.map(\.path), at: repoPath) }
    }

    func commit() async {
        let trimmed = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snapshot.staged.isEmpty, !trimmed.isEmpty else { return }
        isCommitting = true
        defer { isCommitting = false }
        do {
            try await gitService.commit(message: trimmed, at: repoPath, environment: commitEnvironment?() ?? [:])
            commitMessage = ""
            actionErrorMessage = nil
            await refresh(showsSpinner: false)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    func push() async {
        isPushing = true
        defer { isPushing = false }
        do {
            let branch = try await gitService.currentBranch(at: repoPath)
            try await gitService.push(branch: branch, at: repoPath)
            actionErrorMessage = nil
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    func createPullRequest() async {
        guard let ghService else { return }
        isCreatingPR = true
        defer { isCreatingPR = false }
        do {
            let url = try await ghService.createPullRequest(
                title: session.title,
                body: session.goal,
                base: nil,
                at: repoPath
            )
            lastPullRequestURL = url
            actionErrorMessage = nil
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func performWrite(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            actionErrorMessage = nil
            await refresh(showsSpinner: false)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    /// The XCUITest runner is sandboxed away from the fixture checkout; this
    /// automation-only seam performs the edit in the app process, then the
    /// normal live Git pipeline observes it independently.
    func simulateEditForAutomation() async {
        let readme = repoPath.appendingPathComponent("README.md")
        do {
            let existing = (try? String(contentsOf: readme, encoding: .utf8)) ?? ""
            try (existing + "edit-\(UUID().uuidString.prefix(8))\n").write(
                to: readme,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}


/// The project's **Changes** page: the working tree grouped by staging area,
/// each file carrying its real change kind, expandable to its diff, with the
/// commit composer docked at the bottom.
struct DiffPanelView: View {
    let session: Session
    @Bindable var viewModel: DiffPanelViewModel
    @FocusState private var isRefreshButtonFocused: Bool
    @FocusState private var isCommitMessageFocused: Bool
    @State private var collapsedSections: Set<FileDiff.Stage> = []
    @State private var expandedPaths: Set<String> = []

    init(session: Session, gitService: any GitServiceProtocol, ghService: (any GhServiceProtocol)? = nil) {
        self.session = session
        self._viewModel = Bindable(wrappedValue: DiffPanelViewModel(session: session, gitService: gitService, ghService: ghService))
    }

    init(viewModel: DiffPanelViewModel) {
        self.session = viewModel.session
        self._viewModel = Bindable(wrappedValue: viewModel)
    }

    #if DEBUG
    private var isUITesting: Bool {
        ProcessInfo.processInfo.environment["UI_TESTING"] == "1"
    }
    #else
    private var isUITesting: Bool { false }
    #endif

    private var snapshot: GitChangesSnapshot { viewModel.snapshot }

    private var isClean: Bool {
        snapshot.staged.isEmpty && snapshot.unstaged.isEmpty && snapshot.untracked.isEmpty
    }

    private var totalStat: GitDiffStat {
        snapshot.allDiffs.reduce(GitDiffStat(additions: 0, deletions: 0)) { $0 + $1.stat }
    }

    private var canCommit: Bool {
        !snapshot.staged.isEmpty
            && !viewModel.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.isCommitting
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .flotillaInspectorSurface()
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .task { await viewModel.monitor() }
    }

    // MARK: - Toolbar

    /// Repository-level actions live at the top; the bottom bar is reserved for
    /// composing a commit, so the two never compete for the same corner.
    private var toolbar: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Text(fileCountSummary)
                .font(FlotillaTypography.caption.weight(.medium))
                .foregroundStyle(FlotillaColors.textSecondary)
                .contentTransition(.numericText())

            if !totalStat.isEmpty {
                DiffStatBadge(stat: totalStat)
            }

            if viewModel.isLoading && viewModel.hasLoadedOnce {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }

            Spacer(minLength: FlotillaSpacing.small)

            if isUITesting {
                Button("Simulate Edit") {
                    Task { await viewModel.simulateEditForAutomation() }
                }
                .controlSize(.small)
                .accessibilityIdentifier("DiffPanel.SimulateEditButton")
            }

            toolbarButton(
                "Push",
                systemImage: "arrow.up.circle",
                isBusy: viewModel.isPushing,
                identifier: "DiffPanel.PushButton"
            ) {
                Task { await viewModel.push() }
            }

            if viewModel.isGhAvailable {
                toolbarButton(
                    "Create PR",
                    systemImage: "arrow.triangle.pull",
                    isBusy: viewModel.isCreatingPR,
                    identifier: "DiffPanel.CreatePullRequestButton"
                ) {
                    Task { await viewModel.createPullRequest() }
                }
            }

            Button {
                Task { await viewModel.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(FlotillaColors.textSecondary)
            .help("Refresh (⌘R)")
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityIdentifier("DiffPanel.RefreshButton")
            .accessibilityLabel("Refresh")
            .focused($isRefreshButtonFocused)
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
        .frame(minHeight: FlotillaControlHeight.medium)
        .background(FlotillaColors.surface)
    }

    private func toolbarButton(
        _ title: String,
        systemImage: String,
        isBusy: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: FlotillaSpacing.xSmall) {
                if isBusy {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 11)
                } else {
                    Image(systemName: systemImage).font(.system(size: 11))
                }
                Text(title).font(FlotillaTypography.caption2.weight(.medium))
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(FlotillaColors.textSecondary)
        .padding(.horizontal, FlotillaSpacing.small)
        .padding(.vertical, 3)
        .background(FlotillaColors.surfaceElevated, in: Capsule())
        .disabled(isBusy)
        .accessibilityIdentifier(identifier)
    }

    private var fileCountSummary: String {
        let count = snapshot.allDiffs.count
        if count == 0 { return "Working tree clean" }
        return "\(count) changed file\(count == 1 ? "" : "s")"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && !viewModel.hasLoadedOnce {
            ProgressView("Loading changes…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("DiffPanel.Loading")
        } else if let errorMessage = viewModel.errorMessage {
            ContentUnavailableView(
                "Error Loading Changes",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("DiffPanel.Error")
        } else if isClean {
            ContentUnavailableView(
                "No Changes",
                systemImage: "checkmark.circle",
                description: Text("Working tree is clean.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("DiffPanel.Empty")
        } else {
            changeList
        }
    }

    private var changeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                section(
                    .staged,
                    title: "Staged",
                    systemImage: "tray.full",
                    entries: snapshot.staged,
                    bulkTitle: "Unstage All",
                    bulkAction: { Task { await viewModel.unstage(snapshot.staged) } }
                )
                section(
                    .unstaged,
                    title: "Changes",
                    systemImage: "pencil",
                    entries: snapshot.unstaged,
                    bulkTitle: "Stage All",
                    bulkAction: { Task { await viewModel.stage(snapshot.unstaged) } }
                )
                section(
                    .untracked,
                    title: "Untracked",
                    systemImage: "sparkles",
                    entries: snapshot.untracked,
                    bulkTitle: "Stage All",
                    bulkAction: { Task { await viewModel.stage(snapshot.untracked) } }
                )
            }
            .padding(.bottom, FlotillaSpacing.medium)
        }
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("DiffPanel.List")
    }

    @ViewBuilder
    private func section(
        _ stage: FileDiff.Stage,
        title: String,
        systemImage: String,
        entries: [FileDiff],
        bulkTitle: String,
        bulkAction: @escaping () -> Void
    ) -> some View {
        // An empty staging area renders nothing at all: a permanent
        // "Staged (0)" heading is noise on a page that is read at a glance.
        if !entries.isEmpty {
            Section {
                if !collapsedSections.contains(stage) {
                    ForEach(entries, id: \.path) { entry in
                        // Keyed by stage as well as path: the same file can sit
                        // in Staged and Changes at once (partially staged), and
                        // the two rows expand independently.
                        let key = "\(stage.rawValue):\(entry.path)"
                        DiffFileRow(
                            entry: entry,
                            kind: snapshot.status.changeKind(for: entry),
                            isExpanded: expandedPaths.contains(key),
                            onToggleExpanded: {
                                withAnimation(FlotillaMotion.fast.curve) {
                                    if expandedPaths.contains(key) {
                                        expandedPaths.remove(key)
                                    } else {
                                        expandedPaths.insert(key)
                                    }
                                }
                            },
                            onStage: { Task { await viewModel.stage(entry) } },
                            onUnstage: { Task { await viewModel.unstage(entry) } },
                            onDiscard: { Task { await viewModel.discard(entry) } }
                        )
                    }
                }
            } header: {
                sectionHeader(
                    stage,
                    title: title,
                    systemImage: systemImage,
                    entries: entries,
                    bulkTitle: bulkTitle,
                    bulkAction: bulkAction
                )
            }
        }
    }

    private func sectionHeader(
        _ stage: FileDiff.Stage,
        title: String,
        systemImage: String,
        entries: [FileDiff],
        bulkTitle: String,
        bulkAction: @escaping () -> Void
    ) -> some View {
        let isCollapsed = collapsedSections.contains(stage)
        return HStack(spacing: FlotillaSpacing.small) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(FlotillaColors.textTertiary)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .frame(width: 10)

            Image(systemName: systemImage)
                .font(.system(size: 10))
                .foregroundStyle(FlotillaColors.textTertiary)

            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(FlotillaTypography.Tracking.loose2)
                .foregroundStyle(FlotillaColors.textSecondary)

            Text("\(entries.count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(FlotillaColors.textTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(FlotillaColors.surfaceElevated, in: Capsule())

            Spacer(minLength: FlotillaSpacing.small)

            Button(bulkTitle, action: bulkAction)
                .buttonStyle(.plain)
                .font(FlotillaTypography.caption2.weight(.medium))
                .foregroundStyle(FlotillaColors.accent)
                .accessibilityIdentifier("DiffPanel.Section-\(title)-Bulk")
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
        .flotillaLiquidSurface(
            FlotillaColors.surface,
            glassTintOpacity: FlotillaGlassTint.elevated
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FlotillaColors.separator)
                .frame(height: FlotillaBorderWidth.hairline)
        }
        .contentShape(.rect)
        .onTapGesture {
            withAnimation(FlotillaMotion.fast.curve) {
                if isCollapsed {
                    collapsedSections.remove(stage)
                } else {
                    collapsedSections.insert(stage)
                }
            }
        }
        .accessibilityIdentifier("DiffPanel.Section-\(title)")
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            if let actionErrorMessage = viewModel.actionErrorMessage {
                banner(
                    actionErrorMessage,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: FlotillaColors.danger,
                    surface: FlotillaColors.dangerSurface
                )
                .accessibilityIdentifier("DiffPanel.ActionError")
            }

            if let prURL = viewModel.lastPullRequestURL {
                Link(destination: prURL) {
                    banner(
                        "Pull request opened — \(prURL.absoluteString)",
                        systemImage: "arrow.triangle.pull",
                        tint: FlotillaColors.diffAdded,
                        surface: FlotillaColors.diffAddedSurface
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("DiffPanel.PullRequestLink")
            }

            Divider()

            VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
                Text(commitHint)
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(FlotillaColors.textTertiary)

                HStack(spacing: FlotillaSpacing.small) {
                    TextField("Commit message", text: $viewModel.commitMessage)
                        .textFieldStyle(.plain)
                        .font(FlotillaTypography.callout)
                        .autocorrectionDisabled()
                        .textContentType(nil)
                        .focused($isCommitMessageFocused)
                        .onSubmit { if canCommit { Task { await viewModel.commit() } } }
                        .padding(.horizontal, FlotillaSpacing.small)
                        .padding(.vertical, 6)
                        .background(
                            FlotillaColors.surfaceElevated,
                            in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                                .strokeBorder(
                                    isCommitMessageFocused ? FlotillaColors.accent : FlotillaColors.separator,
                                    lineWidth: FlotillaBorderWidth.thin
                                )
                        }
                        .accessibilityIdentifier("DiffPanel.CommitMessageField")

                    Button {
                        Task { await viewModel.commit() }
                    } label: {
                        HStack(spacing: FlotillaSpacing.xSmall) {
                            if viewModel.isCommitting {
                                ProgressView().controlSize(.small).scaleEffect(0.6)
                            }
                            Text("Commit")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FlotillaColors.accent)
                    .disabled(!canCommit)
                    .accessibilityIdentifier("DiffPanel.CommitButton")
                }
            }
            .padding(FlotillaSpacing.medium)
        }
        .background(FlotillaColors.surface)
    }

    private var commitHint: String {
        let count = snapshot.staged.count
        guard count > 0 else { return "Stage files to commit" }
        return "\(count) file\(count == 1 ? "" : "s") staged"
    }

    private func banner(_ text: String, systemImage: String, tint: Color, surface: Color) -> some View {
        HStack(spacing: FlotillaSpacing.small) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(tint)
            Text(text)
                .font(FlotillaTypography.caption2)
                .foregroundStyle(FlotillaColors.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface)
    }
}

/// One file in the working tree: kind marker, path, diff stat, and — on
/// hover — its staging actions. Clicking the row expands the patch inline.
struct DiffFileRow: View {
    let entry: FileDiff
    let kind: GitCommitFileChange.Kind
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onStage: () -> Void
    let onUnstage: () -> Void
    let onDiscard: () -> Void

    @State private var isConfirmingDiscard = false
    @State private var isHovering = false

    private var isStaged: Bool { entry.stage == .staged }

    private var directory: String {
        let components = entry.path.split(separator: "/")
        guard components.count > 1 else { return "" }
        return components.dropLast().joined(separator: "/")
    }

    private var fileName: String {
        String(entry.path.split(separator: "/").last ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                if entry.hunks.isEmpty {
                    Text("No textual diff (this may be a binary file).")
                        .font(FlotillaTypography.caption2)
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .padding(.horizontal, FlotillaSpacing.large)
                        .padding(.bottom, FlotillaSpacing.small)
                } else {
                    ForEach(Array(entry.hunks.enumerated()), id: \.offset) { _, hunk in
                        CommitHunkView(hunk: hunk)
                    }
                }
            }
        }
        .background(isHovering && !isExpanded ? FlotillaColors.textPrimary.opacity(FlotillaStateOpacity.hover) : .clear)
        .accessibilityIdentifier("DiffPanel.File-\(entry.path)")
        .confirmationDialog(
            "Discard changes to \(entry.path)?",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive, action: onDiscard)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(entry.stage == .untracked
                ? "This file will be deleted. This cannot be undone."
                : "Local changes to this file will be lost. This cannot be undone.")
        }
    }

    private var header: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(FlotillaColors.textTertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10)

            FileChangeKindBadge(kind: kind)

            HStack(spacing: FlotillaSpacing.xSmall) {
                Text(fileName)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)

                if !directory.isEmpty {
                    Text(directory)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: FlotillaSpacing.small)

            if !entry.stat.isEmpty {
                DiffStatBadge(stat: entry.stat)
            }

            actions
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, 5)
        .contentShape(.rect)
        .onTapGesture(perform: onToggleExpanded)
        .onHover { isHovering = $0 }
        .contextMenu {
            if isStaged {
                Button("Unstage", action: onUnstage)
            } else {
                Button("Stage", action: onStage)
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.path, forType: .string)
            }
            Divider()
            Button("Discard…", role: .destructive) { isConfirmingDiscard = true }
        }
    }

    /// The staging toggle and discard stay mounted at all times — hover only
    /// changes their contrast — so keyboard and accessibility clients (and the
    /// UI tests that drive them) can always reach them.
    private var actions: some View {
        HStack(spacing: 2) {
            if isStaged {
                rowButton(systemImage: "minus.circle", help: "Unstage", action: onUnstage)
                    .accessibilityIdentifier("DiffPanel.File-\(entry.path)-Unstage")
            } else {
                rowButton(systemImage: "plus.circle", help: "Stage", action: onStage)
                    .accessibilityIdentifier("DiffPanel.File-\(entry.path)-Stage")
            }

            // Discard throws away uncommitted agent work and its immediate
            // neighbour is a reversible staging toggle. They used to render
            // identically — same size, same weight, same grey — so the
            // destructive one is pulled out of the group and coloured.
            Divider()
                .frame(height: 12)
                .padding(.horizontal, 2)

            rowButton(
                systemImage: "trash",
                help: "Discard — cannot be undone",
                isDestructive: true,
                action: { isConfirmingDiscard = true }
            )
            .accessibilityIdentifier("DiffPanel.File-\(entry.path)-Discard")
        }
        .opacity(isHovering ? 1 : 0.35)
        .animation(FlotillaMotion.fast.curve, value: isHovering)
    }

    private func rowButton(
        systemImage: String,
        help: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: isDestructive ? 12 : 11, weight: isDestructive ? .semibold : .regular))
                .frame(width: 20, height: 18)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDestructive ? AnyShapeStyle(FlotillaColors.danger) : AnyShapeStyle(FlotillaColors.textSecondary))
        .help(help)
    }
}
