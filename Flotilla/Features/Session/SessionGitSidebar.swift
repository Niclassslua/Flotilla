import SwiftUI
import Observation
import SessionKit
import GitKit
import DesignSystem

enum SessionGitSidebarTab: String, CaseIterable, Identifiable, Sendable {
    case changes
    case branches
    case log

    var id: Self { self }

    var title: String {
        switch self {
        case .changes: "Changes"
        case .branches: "Branches"
        case .log: "Log"
        }
    }

    var systemImage: String {
        switch self {
        case .changes: "arrow.left.arrow.right"
        case .branches: "arrow.triangle.branch"
        case .log: "clock.arrow.circlepath"
        }
    }
}

enum SessionGitChangeMode: String, CaseIterable, Identifiable, Sendable {
    case uncommitted
    case versusDefault

    var id: Self { self }
}

enum SessionGitChangeKind: Equatable, Sendable {
    case added
    case deleted
    case modified
    case renamed

    var symbol: String {
        switch self {
        case .added: "A"
        case .deleted: "D"
        case .modified: "M"
        case .renamed: "R"
        }
    }

    var label: String {
        switch self {
        case .added: "Added"
        case .deleted: "Deleted"
        case .modified: "Modified"
        case .renamed: "Renamed"
        }
    }
}

enum SessionGitStageState: Equatable, Sendable {
    case unstaged
    case staged
    case partiallyStaged
}

struct SessionGitChangeItem: Identifiable, Sendable {
    let path: String
    let kind: SessionGitChangeKind
    let stat: GitDiffStat
    let stageState: SessionGitStageState?

    var id: String { path }

    var filename: String {
        (path as NSString).lastPathComponent
    }

    var directory: String? {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty || parent == "." ? nil : parent
    }
}

@Observable
@MainActor
final class SessionGitSidebarViewModel {
    static let logPageSize = 100

    let repoPath: URL

    private let gitService: any GitServiceProtocol

    var selectedTab: SessionGitSidebarTab = .changes
    var changeMode: SessionGitChangeMode = .uncommitted
    var selectedLogBranch: String?
    var commitMessage = ""

    private(set) var currentBranch: String?
    private(set) var defaultBranch: String?
    private(set) var changes: [SessionGitChangeItem] = []
    private(set) var branches: [GitBranch] = []
    private(set) var worktrees: [GitWorktree] = []
    private(set) var commits: [GitCommit] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var isCommitting = false
    private(set) var isMutatingBranch = false
    private(set) var hasMoreCommits = false
    private(set) var errorMessage: String?
    private(set) var actionErrorMessage: String?

    init(session: Session, gitService: any GitServiceProtocol) {
        repoPath = (session.worktree?.worktreePath ?? session.workingDirectory).standardizedFileURL
        self.gitService = gitService
    }

    var monitorKey: String {
        "\(selectedTab.rawValue)|\(changeMode.rawValue)|\(selectedLogBranch ?? "")"
    }

    var defaultBranchLabel: String {
        guard let defaultBranch else { return "default" }
        return defaultBranch.hasPrefix("origin/")
            ? String(defaultBranch.dropFirst("origin/".count))
            : defaultBranch
    }

    var canCommit: Bool {
        changes.contains { $0.stageState == .staged || $0.stageState == .partiallyStaged }
            && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isCommitting
    }

    var selectedFileCount: Int {
        changes.filter { $0.stageState == .staged || $0.stageState == .partiallyStaged }.count
    }

    func monitorSelection() async {
        let key = monitorKey
        await refreshSelection()
        guard selectedTab == .changes else { return }

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, monitorKey == key else { return }
            await refreshChanges(showsSpinner: false)
        }
    }

    func refreshSelection() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await loadIdentity()
            switch selectedTab {
            case .changes:
                try await loadChanges()
            case .branches:
                try await loadBranches()
            case .log:
                try await loadLog(reset: true)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshChanges(showsSpinner: Bool = true) async {
        if showsSpinner { isLoading = true }
        defer { if showsSpinner { isLoading = false } }
        do {
            try await loadIdentity()
            try await loadChanges()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleStage(for item: SessionGitChangeItem) async {
        guard item.stageState != nil else { return }
        do {
            switch item.stageState {
            case .staged, .partiallyStaged:
                try await gitService.unstage(paths: [item.path], at: repoPath)
            case .unstaged:
                try await gitService.stage(paths: [item.path], at: repoPath)
            case nil:
                return
            }
            actionErrorMessage = nil
            try await loadChanges()
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    func commit() async {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canCommit, !message.isEmpty else { return }
        isCommitting = true
        defer { isCommitting = false }
        do {
            try await gitService.commit(message: message, at: repoPath)
            commitMessage = ""
            actionErrorMessage = nil
            try await loadChanges()
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    func showCommits(for branch: String) {
        selectedLogBranch = branch
        selectedTab = .log
    }

    func selectLogBranch(_ branch: String) {
        selectedLogBranch = branch
    }

    func loadMoreCommits() async {
        guard hasMoreCommits, !isLoadingMore, let branch = selectedLogBranch else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await gitService.log(
                at: repoPath,
                ref: branch,
                skip: commits.count,
                maxCount: Self.logPageSize
            )
            let known = Set(commits.map(\.sha))
            commits.append(contentsOf: page.filter { !known.contains($0.sha) })
            hasMoreCommits = page.count == Self.logPageSize
            actionErrorMessage = nil
        } catch {
            actionErrorMessage = error.localizedDescription
            hasMoreCommits = false
        }
    }

    func checkout(_ branch: String) async -> Bool {
        guard branch != currentBranch else { return true }
        guard await workingTreeIsClean() else { return false }
        isMutatingBranch = true
        defer { isMutatingBranch = false }
        do {
            try await gitService.checkout(branch: branch, at: repoPath)
            currentBranch = branch
            actionErrorMessage = nil
            try await loadBranches()
            return true
        } catch {
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    func createAndCheckoutBranch(named rawName: String) async -> String? {
        let branch = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { return nil }
        guard await workingTreeIsClean() else { return nil }
        isMutatingBranch = true
        defer { isMutatingBranch = false }
        do {
            try await gitService.createAndCheckoutBranch(named: branch, at: repoPath)
            currentBranch = branch
            selectedLogBranch = branch
            actionErrorMessage = nil
            try await loadBranches()
            return branch
        } catch {
            actionErrorMessage = error.localizedDescription
            return nil
        }
    }

    func isBranchMerged(_ branch: String) async -> Bool? {
        guard let defaultBranch else { return nil }
        do {
            let merged = try await gitService.isBranchMerged(branch, into: defaultBranch, at: repoPath)
            actionErrorMessage = nil
            return merged
        } catch {
            actionErrorMessage = error.localizedDescription
            return nil
        }
    }

    func deleteBranch(_ branch: String, force: Bool) async {
        isMutatingBranch = true
        defer { isMutatingBranch = false }
        do {
            try await gitService.deleteBranch(branch, force: force, at: repoPath)
            if selectedLogBranch == branch { selectedLogBranch = currentBranch }
            actionErrorMessage = nil
            try await loadBranches()
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    private func loadIdentity() async throws {
        let branch = try await gitService.currentBranch(at: repoPath)
        currentBranch = branch
        defaultBranch = (try? await gitService.defaultBranch(at: repoPath)) ?? branch
        if selectedLogBranch == nil { selectedLogBranch = branch }
    }

    private func loadChanges() async throws {
        switch changeMode {
        case .uncommitted:
            let snapshot = try await gitService.changes(at: repoPath)
            changes = Self.items(from: snapshot)
        case .versusDefault:
            guard let defaultBranch else {
                changes = []
                return
            }
            let compared = try await gitService.changesCompared(to: defaultBranch, at: repoPath)
            changes = compared
                .map(Self.item(from:))
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }

    private func loadBranches() async throws {
        async let branchRequest = gitService.branches(at: repoPath)
        async let worktreeRequest = gitService.listWorktrees(at: repoPath)
        let (allBranches, loadedWorktrees) = try await (branchRequest, worktreeRequest)
        worktrees = loadedWorktrees
        branches = allBranches
            .filter { !$0.isRemote }
            .sorted { lhs, rhs in
                let lhsIsCurrent = lhs.name == currentBranch
                let rhsIsCurrent = rhs.name == currentBranch
                if lhsIsCurrent != rhsIsCurrent { return lhsIsCurrent }
                if lhs.lastCommitDate != rhs.lastCommitDate {
                    return lhs.lastCommitDate > rhs.lastCommitDate
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private func loadLog(reset: Bool) async throws {
        if branches.isEmpty { try await loadBranches() }
        let branch = selectedLogBranch ?? currentBranch
        guard let branch else {
            commits = []
            hasMoreCommits = false
            return
        }
        selectedLogBranch = branch
        let page = try await gitService.log(
            at: repoPath,
            ref: branch,
            skip: reset ? 0 : commits.count,
            maxCount: Self.logPageSize
        )
        if reset { commits = page } else { commits.append(contentsOf: page) }
        hasMoreCommits = page.count == Self.logPageSize
    }

    private func workingTreeIsClean() async -> Bool {
        do {
            guard try await gitService.status(at: repoPath).isClean else {
                actionErrorMessage = "Commit or discard uncommitted changes before switching branches."
                return false
            }
            return true
        } catch {
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    private static func items(from snapshot: GitChangesSnapshot) -> [SessionGitChangeItem] {
        let statusByPath = Dictionary(
            snapshot.status.entries.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let paths = Set(snapshot.allDiffs.map(\.path))

        return paths.map { path in
            let staged = snapshot.staged.filter { $0.path == path }
            let unstaged = (snapshot.unstaged + snapshot.untracked).filter { $0.path == path }
            let stageState: SessionGitStageState
            if !staged.isEmpty, !unstaged.isEmpty {
                stageState = .partiallyStaged
            } else if !staged.isEmpty {
                stageState = .staged
            } else {
                stageState = .unstaged
            }
            let stat = (staged + unstaged).reduce(
                GitDiffStat(additions: 0, deletions: 0)
            ) { $0 + $1.stat }
            return SessionGitChangeItem(
                path: path,
                kind: kind(for: statusByPath[path]),
                stat: stat,
                stageState: stageState
            )
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func item(from change: GitCommitFileChange) -> SessionGitChangeItem {
        let kind: SessionGitChangeKind = switch change.kind {
        case .added: .added
        case .deleted: .deleted
        case .renamed, .copied: .renamed
        case .modified, .typeChanged, .unmerged: .modified
        }

        return SessionGitChangeItem(
            path: change.path,
            kind: kind,
            stat: change.stat,
            stageState: nil
        )
    }

    private static func kind(for status: GitStatusEntry?) -> SessionGitChangeKind {
        guard let status else { return .modified }
        let markers = [status.indexStatus, status.worktreeStatus]
        if status.isUntracked || markers.contains("A") { return .added }
        if markers.contains("D") { return .deleted }
        if markers.contains("R") { return .renamed }
        return .modified
    }
}

struct SessionGitSidebar: View {
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
        .background(FlotillaColors.sidebar)
        .accessibilityIdentifier("GitSidebar")
        .task(id: viewModel.monitorKey) {
            await viewModel.monitorSelection()
        }
        .confirmationDialog(
            pendingDeletion.map { "Delete \($0.branch)?" } ?? "Delete branch?",
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

    private var header: some View {
        HStack(spacing: FlotillaSpacing.small) {
            GitBranchIcon(size: FlotillaIconSize.small)
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
        .background(FlotillaColors.surface)
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
        .background(FlotillaColors.surface)
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
        .background(FlotillaColors.surface)
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
            .background(FlotillaColors.surface)
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
                            Label(branch.name, systemImage: "checkmark")
                        } else {
                            Text(branch.name)
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
        .background(FlotillaColors.surface)
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
                Text(branch.name)
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
