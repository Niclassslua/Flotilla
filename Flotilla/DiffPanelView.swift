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

    private(set) var snapshot = GitChangesSnapshot(
        status: GitStatus(entries: []),
        staged: [],
        unstaged: [],
        untracked: []
    )
    private(set) var isLoading = false
    private(set) var hasLoadedOnce = false
    private(set) var errorMessage: String?

    private var repoPath: URL {
        session.worktree?.worktreePath ?? session.workingDirectory
    }

    init(session: Session, gitService: any GitServiceProtocol) {
        self.session = session
        self.gitService = gitService
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

    init(session: Session, gitService: any GitServiceProtocol) {
        self.session = session
        self._viewModel = Bindable(wrappedValue: DiffPanelViewModel(session: session, gitService: gitService))
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
                .accessibilityIdentifier("DiffPanel.Empty")
                .background(FlotillaColors.canvas)
            } else {
                List {
                    Section("Staged (\(viewModel.snapshot.staged.count))") {
                        ForEach(viewModel.snapshot.staged, id: \.path) { entry in
                            DiffFileRow(entry: entry, isStaged: true)
                        }
                    }

                    Section("Unstaged (\(viewModel.snapshot.unstaged.count))") {
                        ForEach(viewModel.snapshot.unstaged, id: \.path) { entry in
                            DiffFileRow(entry: entry, isStaged: false)
                        }
                    }

                    if !viewModel.snapshot.untracked.isEmpty {
                        Section("Untracked (\(viewModel.snapshot.untracked.count))") {
                            ForEach(viewModel.snapshot.untracked, id: \.path) { entry in
                                HStack {
                                    Image(systemName: "doc")
                                        .foregroundStyle(.secondary)
                                    Text(entry.path)
                                        .font(.system(.body, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .padding(.vertical, 2)
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
        .background(FlotillaColors.canvas)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                if isUITesting {
                    Button("Simulate Edit") {
                        Task { await viewModel.simulateEditForAutomation() }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("DiffPanel.SimulateEditButton")
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
            .background(FlotillaColors.surface)
        }
        .task {
            await viewModel.monitor()
        }
    }
}

struct DiffFileRow: View {
    let entry: FileDiff
    let isStaged: Bool

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
                Text("+\(additions) −\(deletions)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isStaged ? FlotillaColors.diffAdded : FlotillaColors.diffRemoved)
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityIdentifier("DiffPanel.File-\(entry.path)")
    }
}