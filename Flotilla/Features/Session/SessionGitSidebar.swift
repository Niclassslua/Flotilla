import SwiftUI
import Observation
import SessionKit
import GitKit
import DesignSystem

struct SessionGitSidebar: View {
    @Environment(\.flotillaLiquidGlassEnabled) private var liquidGlassEnabled
    @Bindable var viewModel: SessionGitSidebarViewModel
    @Bindable var store: AppStore
    let session: Session
    let project: Project
    let onClose: () -> Void
    let onOpenCommit: (GitCommit, String) -> Void

    @State private var isCreatingBranch = false
    @State private var branchDraft = ""
    @State private var pendingDeletion: PendingBranchDeletion?
    @FocusState private var isBranchFieldFocused: Bool
    @FocusState private var isCommitFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabBar
            Divider()

            if let actionError = viewModel.actionErrorMessage {
                actionErrorBanner(actionError)
                Divider()
            }

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .flotillaInspectorSurface(ignoresSafeAreaEdges: .top)
        .accessibilityIdentifier("GitSidebar")
        .task(id: viewModel.monitorKey) {
            await viewModel.monitorSelection()
        }
        .confirmationDialog(
            pendingDeletion.map { "Delete \(BranchNaming.displayName(for: $0.branch))?" } ?? "Delete branch?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { deletion in
            Button(deletion.isMerged ? "Delete Branch" : "Delete Unmerged Branch", role: .destructive) {
                Task { await viewModel.deleteBranch(deletion.branch, force: !deletion.isMerged) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { deletion in
            if deletion.isMerged {
                Text("The local branch will be deleted. Remote branches are not affected.")
            } else {
                Text("This branch contains commits not merged into \(viewModel.defaultBranchLabel). Deleting it may make that work difficult to recover.")
            }
        }
    }

    /// Bars sit on the inspector glass in Liquid Glass mode; an opaque fill
    /// would cover it and, through the safe area, the band under the toolbar.
    private var barBackground: Color {
        liquidGlassEnabled ? .clear : FlotillaColors.surface
    }

    private var header: some View {
        HStack(spacing: FlotillaSpacing.small) {
            GitIcon(size: FlotillaIconSize.small)
                .foregroundStyle(FlotillaColors.accent)
                .accessibilityHidden(true)
            Text("Git")
                .font(FlotillaTypography.callout.weight(.semibold))
                .foregroundStyle(FlotillaColors.textPrimary)
            if let currentBranch = viewModel.currentBranch {
                Text(currentBranch)
                    .font(FlotillaTypography.caption2.monospaced())
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: FlotillaIconSize.xSmall, weight: .semibold))
                    .frame(width: FlotillaControlHeight.small, height: FlotillaControlHeight.small)
            }
            .buttonStyle(.plain)
            .foregroundStyle(FlotillaColors.textSecondary)
            .help("Close Git sidebar")
            .accessibilityLabel("Close Git sidebar")
            .accessibilityIdentifier("GitSidebar.Close")
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .frame(height: 38)
        .background(barBackground)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(SessionGitSidebarTab.allCases) { tab in
                Button {
                    viewModel.selectedTab = tab
                } label: {
                    VStack(spacing: 4) {
                        HStack(spacing: 5) {
                            if tab == .branches {
                                GitBranchIcon(size: FlotillaIconSize.small)
                            } else {
                                Image(systemName: tab.systemImage)
                            }
                            Text(tab.title)
                        }
                        .font(FlotillaTypography.caption.weight(
                                viewModel.selectedTab == tab ? .semibold : .regular
                            ))
                            .foregroundStyle(
                                viewModel.selectedTab == tab
                                    ? FlotillaColors.textPrimary
                                    : FlotillaColors.textTertiary
                            )
                            .frame(maxWidth: .infinity)
                        Rectangle()
                            .fill(viewModel.selectedTab == tab ? FlotillaColors.accent : .clear)
                            .frame(height: 2)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("GitSidebar.Tab.\(tab.title)")
            }
        }
        .frame(height: 38)
        .background(barBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Git sidebar tabs")
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.selectedTab {
        case .changes:
            changesView
        case .branches:
            branchesView
        case .log:
            logView
        }
    }

    private var changesView: some View {
        VStack(spacing: 0) {
            Picker("Comparison", selection: $viewModel.changeMode) {
                Text("Uncommitted").tag(SessionGitChangeMode.uncommitted)
                Text("Vs \(viewModel.defaultBranchLabel)").tag(SessionGitChangeMode.versusDefault)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(FlotillaSpacing.medium)
            .accessibilityIdentifier("GitSidebar.Changes.Mode")

            Divider()
            changeList

            if viewModel.changeMode == .uncommitted {
                Divider()
                commitComposer
            }
        }
    }

    @ViewBuilder
    private var changeList: some View {
        if viewModel.isLoading && viewModel.changes.isEmpty {
            loadingState("Reading changes…")
        } else if let error = viewModel.errorMessage {
            errorState("Couldn’t Read Changes", message: error)
        } else if viewModel.changes.isEmpty {
            ContentUnavailableView(
                viewModel.changeMode == .uncommitted ? "Working Tree Clean" : "No Branch Changes",
                systemImage: "checkmark.circle",
                description: Text(
                    viewModel.changeMode == .uncommitted
                        ? "There are no uncommitted files."
                        : "This branch matches \(viewModel.defaultBranchLabel)."
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.changes) { item in
                        GitSidebarChangeRow(
                            item: item,
                            showsStageControl: viewModel.changeMode == .uncommitted,
                            onToggleStage: { Task { await viewModel.toggleStage(for: item) } }
                        )
                        Divider().padding(.leading, FlotillaSpacing.medium)
                    }
                }
            }
            .accessibilityIdentifier("GitSidebar.Changes.List")
        }
    }

    private var commitComposer: some View {
        VStack(spacing: FlotillaSpacing.small) {
            TextField("Commit message", text: $viewModel.commitMessage)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textContentType(nil)
                .focused($isCommitFieldFocused)
                .onSubmit {
                    if viewModel.canCommit { Task { await viewModel.commit() } }
                }
                .accessibilityIdentifier("GitSidebar.Changes.CommitMessage")

            HStack(spacing: FlotillaSpacing.small) {
                Text("\(viewModel.selectedFileCount) selected")
                    .font(FlotillaTypography.caption2.monospacedDigit())
                    .foregroundStyle(FlotillaColors.textTertiary)
                Spacer()
                if viewModel.isCommitting {
                    ProgressView().controlSize(.small)
                }
                Button("Commit") {
                    Task { await viewModel.commit() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(FlotillaColors.accent)
                .disabled(!viewModel.canCommit)
                .accessibilityIdentifier("GitSidebar.Changes.Commit")
            }
        }
        .padding(FlotillaSpacing.medium)
        .background(barBackground)
    }

    private var branchesView: some View {
        VStack(spacing: 0) {
            newBranchControl
            Divider()

            if viewModel.isLoading && viewModel.branches.isEmpty {
                loadingState("Reading branches…")
            } else if let error = viewModel.errorMessage {
                errorState("Couldn’t Read Branches", message: error)
            } else if viewModel.branches.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("No Local Branches")
                    } icon: {
                        GitBranchIcon(size: 28)
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.branches, id: \.name) { branch in
                            branchRow(branch)
                            Divider().padding(.leading, FlotillaSpacing.medium)
                        }
                    }
                }
                .accessibilityIdentifier("GitSidebar.Branches.List")
            }
        }
    }

    @ViewBuilder
    private var newBranchControl: some View {
        if isCreatingBranch {
            HStack(spacing: FlotillaSpacing.small) {
                TextField("Branch name", text: $branchDraft)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textContentType(nil)
                    .focused($isBranchFieldFocused)
                    .onSubmit(createBranch)
                    .accessibilityIdentifier("GitSidebar.Branches.Name")
                Button("Cancel", action: cancelBranchCreation)
                    .buttonStyle(.plain)
                    .foregroundStyle(FlotillaColors.textSecondary)
                Button("Create", action: createBranch)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(FlotillaColors.accent)
                    .disabled(
                        branchDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || viewModel.isMutatingBranch
                    )
                    .accessibilityIdentifier("GitSidebar.Branches.Create")
            }
            .padding(FlotillaSpacing.medium)
            .background(FlotillaColors.surfaceElevated)
            .defaultFocus($isBranchFieldFocused, true)
        } else {
            Button {
                isCreatingBranch = true
                branchDraft = ""
            } label: {
                Label("New Branch", systemImage: "plus")
                    .font(FlotillaTypography.caption.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(FlotillaColors.textSecondary)
            .padding(.horizontal, FlotillaSpacing.medium)
            .frame(height: 38)
            .background(barBackground)
            .accessibilityIdentifier("GitSidebar.Branches.New")
        }
    }

    private func branchRow(_ branch: GitBranch) -> some View {
        let associated = associatedSessions(with: branch.name)
        let hasWorkingAgent = associated.contains { $0.status == .working }
        let hasActiveSession = associated.contains { session in
            session.status == nil || session.status == .working || session.status == .waitingForInput
        }
        let isCurrent = branch.name == viewModel.currentBranch
        let checkedOutElsewhere = viewModel.worktrees.contains { worktree in
            worktree.branch == branch.name
                && worktree.path.standardizedFileURL != viewModel.repoPath
        }
        let deleteProtection = branchDeleteProtection(
            branch: branch.name,
            isCurrent: isCurrent,
            hasActiveSession: hasActiveSession,
            checkedOutElsewhere: checkedOutElsewhere
        )

        return GitSidebarBranchRow(
            branch: branch,
            isCurrentSessionBranch: isCurrent,
            hasWorkingAgent: hasWorkingAgent,
            checkoutDisabledReason: isCurrent
                ? "This branch is already checked out."
                : checkedOutElsewhere ? "This branch is checked out in another worktree." : nil,
            deleteDisabledReason: deleteProtection,
            onViewCommits: { viewModel.showCommits(for: branch.name) },
            onCheckout: {
                Task {
                    if await viewModel.checkout(branch.name) {
                        store.updateSessionBranch(sessionID: session.id, branchName: branch.name)
                    }
                }
            },
            onDelete: { prepareToDelete(branch.name) }
        )
    }

    private var logView: some View {
        VStack(spacing: 0) {
            logToolbar
            Divider()

            if viewModel.isLoading && viewModel.commits.isEmpty {
                loadingState("Reading commits…")
            } else if let error = viewModel.errorMessage {
                errorState("Couldn’t Read Commits", message: error)
            } else if viewModel.commits.isEmpty {
                ContentUnavailableView(
                    "No Commits",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("This branch has no commit history.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.commits) { commit in
                            Button {
                                onOpenCommit(commit, viewModel.selectedLogBranch ?? viewModel.currentBranch ?? "HEAD")
                            } label: {
                                GitSidebarCommitRow(commit: commit)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("GitSidebar.Log.Commit-\(commit.shortSHA)")
                            .task {
                                if commit.id == viewModel.commits.last?.id {
                                    await viewModel.loadMoreCommits()
                                }
                            }
                            Divider().padding(.leading, FlotillaSpacing.medium)
                        }

                        if viewModel.isLoadingMore {
                            ProgressView()
                                .controlSize(.small)
                                .padding(FlotillaSpacing.medium)
                        }
                    }
                }
                .accessibilityIdentifier("GitSidebar.Log.List")
            }
        }
    }

    private var logToolbar: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Menu {
                ForEach(viewModel.branches, id: \.name) { branch in
                    Button {
                        viewModel.selectLogBranch(branch.name)
                    } label: {
                        if viewModel.selectedLogBranch == branch.name {
                            Label(BranchNaming.displayName(for: branch.name), systemImage: "checkmark")
                        } else {
                            Text(BranchNaming.displayName(for: branch.name))
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    GitBranchIcon(size: 11)
                    Text(viewModel.selectedLogBranch ?? viewModel.currentBranch ?? "Branch")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(FlotillaTypography.caption.monospaced())
                .foregroundStyle(FlotillaColors.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityIdentifier("GitSidebar.Log.Branch")

            Spacer()
            Text("\(viewModel.commits.count)")
                .font(FlotillaTypography.caption2.monospacedDigit())
                .foregroundStyle(FlotillaColors.textTertiary)
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .frame(height: 38)
        .background(barBackground)
    }

    private func associatedSessions(with branch: String) -> [Session] {
        store.sessions(for: project).filter { candidate in
            if let worktreeBranch = candidate.worktree?.branchName {
                return worktreeBranch == branch
            }
            return candidate.workingDirectory.standardizedFileURL == project.rootPath.standardizedFileURL
                && branch == viewModel.currentBranch
        }
    }

    private func branchDeleteProtection(
        branch: String,
        isCurrent: Bool,
        hasActiveSession: Bool,
        checkedOutElsewhere: Bool
    ) -> String? {
        if isCurrent { return "The current branch cannot be deleted." }
        if branch == viewModel.defaultBranch { return "The default branch cannot be deleted." }
        if hasActiveSession { return "An active agent session is using this branch." }
        if checkedOutElsewhere { return "This branch is checked out in another worktree." }
        return nil
    }

    private func createBranch() {
        let draft = branchDraft
        Task {
            guard let branch = await viewModel.createAndCheckoutBranch(named: draft) else { return }
            store.updateSessionBranch(sessionID: session.id, branchName: branch)
            branchDraft = ""
            isCreatingBranch = false
            isBranchFieldFocused = false
        }
    }

    private func cancelBranchCreation() {
        branchDraft = ""
        isCreatingBranch = false
        isBranchFieldFocused = false
    }

    private func prepareToDelete(_ branch: String) {
        Task {
            guard let merged = await viewModel.isBranchMerged(branch) else { return }
            pendingDeletion = PendingBranchDeletion(branch: branch, isMerged: merged)
        }
    }

    private func actionErrorBanner(_ message: String) -> some View {
        HStack(spacing: FlotillaSpacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(FlotillaColors.danger)
                .accessibilityHidden(true)
            Text(message)
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textSecondary)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button(action: viewModel.clearActionError) {
                Image(systemName: "xmark")
                    .frame(width: FlotillaControlHeight.xSmall, height: FlotillaControlHeight.xSmall)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
        .background(FlotillaColors.dangerSurface)
        .accessibilityIdentifier("GitSidebar.ActionError")
    }

    private func loadingState(_ label: String) -> some View {
        VStack(spacing: FlotillaSpacing.small) {
            ProgressView().controlSize(.small)
            Text(label)
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ title: String, message: String) -> some View {
        ContentUnavailableView(
            title,
            systemImage: "exclamationmark.triangle",
            description: Text(message)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PendingBranchDeletion: Identifiable {
    let branch: String
    let isMerged: Bool

    var id: String { branch }
}

private struct GitSidebarChangeRow: View {
    let item: SessionGitChangeItem
    let showsStageControl: Bool
    let onToggleStage: () -> Void

    private var tint: Color {
        switch item.kind {
        case .added: FlotillaColors.diffAdded
        case .deleted: FlotillaColors.diffRemoved
        case .modified: FlotillaColors.warning
        case .renamed: FlotillaColors.statusReady
        }
    }

    var body: some View {
        HStack(spacing: FlotillaSpacing.small) {
            if showsStageControl {
                Button(action: onToggleStage) {
                    Image(systemName: stageSymbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(stageTint)
                        .frame(width: FlotillaControlHeight.xSmall, height: FlotillaControlHeight.small)
                }
                .buttonStyle(.plain)
                .help(stageHelp)
                .accessibilityLabel(stageHelp)
                .accessibilityIdentifier("GitSidebar.Changes.Stage-\(item.path)")
            }

            Text(item.kind.symbol)
                .font(FlotillaTypography.caption2.weight(.bold).monospaced())
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel(item.kind.label)

            HStack(spacing: 5) {
                Text(item.filename)
                    .font(FlotillaTypography.caption.weight(.medium))
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)
                if let directory = item.directory {
                    Text(directory)
                        .font(FlotillaTypography.caption2)
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: FlotillaSpacing.xSmall)
            GitSidebarDiffStat(stat: item.stat)
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .frame(minHeight: 38)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(item.kind.label), \(item.path), \(item.stat.additions) additions, \(item.stat.deletions) deletions"
        )
        .accessibilityIdentifier("GitSidebar.Changes.File-\(item.path)")
    }

    private var stageSymbol: String {
        switch item.stageState {
        case .staged: "checkmark.square.fill"
        case .partiallyStaged: "minus.square.fill"
        case .unstaged, nil: "square"
        }
    }

    private var stageTint: Color {
        switch item.stageState {
        case .staged: FlotillaColors.accent
        case .partiallyStaged: FlotillaColors.warning
        case .unstaged, nil: FlotillaColors.textTertiary
        }
    }

    private var stageHelp: String {
        switch item.stageState {
        case .staged: "Unstage \(item.filename)"
        case .partiallyStaged: "Unstage all changes in \(item.filename)"
        case .unstaged, nil: "Stage \(item.filename)"
        }
    }
}

private struct GitSidebarDiffStat: View {
    let stat: GitDiffStat

    var body: some View {
        HStack(spacing: 4) {
            if stat.additions > 0 {
                Text("+\(stat.additions)")
                    .foregroundStyle(FlotillaColors.diffAdded)
            }
            if stat.deletions > 0 {
                Text("−\(stat.deletions)")
                    .foregroundStyle(FlotillaColors.diffRemoved)
            }
            if stat.isEmpty {
                Text("—")
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
        }
        .font(FlotillaTypography.caption2.monospacedDigit())
        .fixedSize()
    }
}

private struct GitSidebarBranchRow: View {
    private enum FocusedAction: Hashable {
        case viewCommits
        case checkout
        case delete
    }

    let branch: GitBranch
    let isCurrentSessionBranch: Bool
    let hasWorkingAgent: Bool
    let checkoutDisabledReason: String?
    let deleteDisabledReason: String?
    let onViewCommits: () -> Void
    let onCheckout: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @FocusState private var focusedAction: FocusedAction?

    private var showsActions: Bool { isHovering || focusedAction != nil }

    var body: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Circle()
                .fill(hasWorkingAgent ? FlotillaColors.statusWorking : .clear)
                .strokeBorder(
                    hasWorkingAgent ? FlotillaColors.statusWorking : FlotillaColors.separatorStrong,
                    lineWidth: FlotillaBorderWidth.thin
                )
                .frame(width: 7, height: 7)
                .accessibilityLabel(hasWorkingAgent ? "Agent working" : "No agent working")

            VStack(alignment: .leading, spacing: 2) {
                Text(BranchNaming.displayName(for: branch.name))
                    .font(FlotillaTypography.caption.weight(isCurrentSessionBranch ? .semibold : .regular).monospaced())
                    .foregroundStyle(
                        isCurrentSessionBranch ? FlotillaColors.accent : FlotillaColors.textPrimary
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(lastCommitLabel)
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(FlotillaColors.textTertiary)
            }

            Spacer(minLength: 0)
            HStack(spacing: 2) {
                actionButton(
                    systemImage: "list.bullet",
                    help: "View commits",
                    focus: .viewCommits,
                    action: onViewCommits
                )
                actionButton(
                    systemImage: "arrow.right.circle",
                    help: checkoutDisabledReason ?? "Checkout",
                    focus: .checkout,
                    isDisabled: checkoutDisabledReason != nil,
                    action: onCheckout
                )
                actionButton(
                    systemImage: "trash",
                    help: deleteDisabledReason ?? "Delete branch",
                    focus: .delete,
                    isDisabled: deleteDisabledReason != nil,
                    isDestructive: true,
                    action: onDelete
                )
            }
            .opacity(showsActions ? 1 : 0)
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .frame(minHeight: 44)
        .background(
            isCurrentSessionBranch
                ? FlotillaColors.accent.opacity(FlotillaStateOpacity.selected)
                : isHovering ? FlotillaColors.textPrimary.opacity(FlotillaStateOpacity.hover) : .clear
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isCurrentSessionBranch ? FlotillaColors.accent : .clear)
                .frame(width: 2)
        }
        .onHover { isHovering = $0 }
        .withFlotillaMotion(.fast, value: showsActions)
        .accessibilityIdentifier("GitSidebar.Branches.Row-\(branch.name)")
    }

    private var lastCommitLabel: String {
        guard branch.lastCommitDate != .distantPast else { return "Commit date unavailable" }
        return "Last commit \(SessionElapsed.since(branch.lastCommitDate))"
    }

    private func actionButton(
        systemImage: String,
        help: String,
        focus: FocusedAction,
        isDisabled: Bool = false,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: FlotillaIconSize.xSmall, weight: .medium))
                .frame(width: FlotillaControlHeight.xSmall, height: FlotillaControlHeight.small)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDestructive ? FlotillaColors.danger : FlotillaColors.textSecondary)
        .disabled(isDisabled)
        .help(help)
        .accessibilityLabel(help)
        .focused($focusedAction, equals: focus)
    }
}

private struct GitSidebarCommitRow: View {
    let commit: GitCommit

    var body: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Text(commit.shortSHA)
                .font(FlotillaTypography.caption2.monospaced())
                .foregroundStyle(FlotillaColors.accent)
                .frame(width: 58, alignment: .leading)
            Text(commit.subject)
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(SessionElapsed.since(commit.authorDate))
                .font(FlotillaTypography.caption2.monospacedDigit())
                .foregroundStyle(FlotillaColors.textTertiary)
                .fixedSize()
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .frame(minHeight: 38)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(commit.shortSHA), \(commit.subject), \(SessionElapsed.since(commit.authorDate)) ago")
    }
}
