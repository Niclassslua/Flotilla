import SwiftUI
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

    init(session: Session, gitService: any GitServiceProtocol, ghService: (any GhServiceProtocol)? = nil) {
        self.session = session
        self.gitService = gitService
        self.ghService = ghService
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

    func commit() async {
        let trimmed = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snapshot.staged.isEmpty, !trimmed.isEmpty else { return }
        isCommitting = true
        defer { isCommitting = false }
        do {
            try await gitService.commit(message: trimmed, at: repoPath)
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

struct DiffPanelView: View {
    let session: Session
    @Bindable var viewModel: DiffPanelViewModel
    @FocusState private var isRefreshButtonFocused: Bool
    @FocusState private var isCommitMessageFocused: Bool

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

    private var canCommit: Bool {
        !viewModel.snapshot.staged.isEmpty
            && !viewModel.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.isCommitting
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading && !viewModel.hasLoadedOnce {
                ProgressView("Loading changes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(FlotillaColors.canvas)
                    .accessibilityIdentifier("DiffPanel.Loading")
            } else if let errorMessage = viewModel.errorMessage {
                ContentUnavailableView(
                    "Error Loading Changes",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("DiffPanel.Error")
                .background(FlotillaColors.canvas)
            } else if viewModel.snapshot.staged.isEmpty &&
                       viewModel.snapshot.unstaged.isEmpty &&
                       viewModel.snapshot.untracked.isEmpty {
                ContentUnavailableView(
                    "No Changes",
                    systemImage: "checkmark.circle",
                    description: Text("Working tree is clean.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("DiffPanel.Empty")
                .background(FlotillaColors.canvas)
            } else {
                List {
                    Section("Staged (\(viewModel.snapshot.staged.count))") {
                        ForEach(viewModel.snapshot.staged, id: \.path) { entry in
                            DiffFileRow(
                                entry: entry,
                                onStage: {},
                                onUnstage: { Task { await viewModel.unstage(entry) } },
                                onDiscard: { Task { await viewModel.discard(entry) } }
                            )
                        }
                    }

                    Section("Unstaged (\(viewModel.snapshot.unstaged.count))") {
                        ForEach(viewModel.snapshot.unstaged, id: \.path) { entry in
                            DiffFileRow(
                                entry: entry,
                                onStage: { Task { await viewModel.stage(entry) } },
                                onUnstage: {},
                                onDiscard: { Task { await viewModel.discard(entry) } }
                            )
                        }
                    }

                    if !viewModel.snapshot.untracked.isEmpty {
                        Section("Untracked (\(viewModel.snapshot.untracked.count))") {
                            ForEach(viewModel.snapshot.untracked, id: \.path) { entry in
                                DiffFileRow(
                                    entry: entry,
                                    onStage: { Task { await viewModel.stage(entry) } },
                                    onUnstage: {},
                                    onDiscard: { Task { await viewModel.discard(entry) } }
                                )
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(FlotillaColors.canvas)
                .accessibilityIdentifier("DiffPanel.List")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlotillaColors.canvas)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let actionErrorMessage = viewModel.actionErrorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(actionErrorMessage)
                            .font(.caption)
                            .lineLimit(2)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.09))
                    .accessibilityIdentifier("DiffPanel.ActionError")
                }

                if let prURL = viewModel.lastPullRequestURL {
                    Link(destination: prURL) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.pull")
                            Text("Pull request opened — \(prURL.absoluteString)")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.caption)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(FlotillaColors.diffAddedSurface)
                    .accessibilityIdentifier("DiffPanel.PullRequestLink")
                }

                Divider()

                HStack(spacing: 8) {
                    TextField("Commit message", text: $viewModel.commitMessage)
                        .textFieldStyle(.roundedBorder)
                        .focused($isCommitMessageFocused)
                        .onSubmit { if canCommit { Task { await viewModel.commit() } } }
                        .accessibilityIdentifier("DiffPanel.CommitMessageField")

                    if viewModel.isCommitting {
                        ProgressView().controlSize(.small)
                    }
                    Button("Commit") {
                        Task { await viewModel.commit() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCommit)
                    .accessibilityIdentifier("DiffPanel.CommitButton")
                }
                .padding(12)

                Divider()

                HStack {
                    if isUITesting {
                        Button("Simulate Edit") {
                            Task { await viewModel.simulateEditForAutomation() }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("DiffPanel.SimulateEditButton")
                    }

                    if viewModel.isPushing {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        Task { await viewModel.push() }
                    } label: {
                        Label("Push", systemImage: "arrow.up.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isPushing)
                    .accessibilityIdentifier("DiffPanel.PushButton")

                    if viewModel.isGhAvailable {
                        if viewModel.isCreatingPR {
                            ProgressView().controlSize(.small)
                        }
                        Button {
                            Task { await viewModel.createPullRequest() }
                        } label: {
                            Label("Create PR", systemImage: "arrow.triangle.pull")
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isCreatingPR)
                        .accessibilityIdentifier("DiffPanel.CreatePullRequestButton")
                    }

                    Spacer()
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("r", modifiers: .command)
                    .accessibilityIdentifier("DiffPanel.RefreshButton")
                    .focused($isRefreshButtonFocused)
                }
                .padding(12)
            }
            .background(FlotillaColors.surface)
        }
        .task {
            await viewModel.monitor()
        }
    }
}

struct DiffFileRow: View {
    let entry: FileDiff
    let onStage: () -> Void
    let onUnstage: () -> Void
    let onDiscard: () -> Void

    @State private var isConfirmingDiscard = false

    private var isStaged: Bool { entry.stage == .staged }

    private var additions: Int {
        entry.hunks.flatMap(\.lines).filter { $0.hasPrefix("+") }.count
    }

    private var deletions: Int {
        entry.hunks.flatMap(\.lines).filter { $0.hasPrefix("-") }.count
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .foregroundStyle(isStaged ? FlotillaColors.diffAdded : FlotillaColors.diffRemoved)
                .font(.system(size: 14))

            Text(entry.path)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            if additions > 0 || deletions > 0 {
                Text("+\(additions.formatted()) −\(deletions.formatted())")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isStaged ? FlotillaColors.diffAdded : FlotillaColors.diffRemoved)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Spacer()

            HStack(spacing: 2) {
                if isStaged {
                    rowButton(systemImage: "minus.circle", help: "Unstage", action: onUnstage)
                        .accessibilityIdentifier("DiffPanel.File-\(entry.path)-Unstage")
                } else {
                    rowButton(systemImage: "plus.circle", help: "Stage", action: onStage)
                        .accessibilityIdentifier("DiffPanel.File-\(entry.path)-Stage")
                }
                rowButton(systemImage: "trash", help: "Discard", action: { isConfirmingDiscard = true })
                    .accessibilityIdentifier("DiffPanel.File-\(entry.path)-Discard")
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
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

    private func rowButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .frame(width: 20, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}
