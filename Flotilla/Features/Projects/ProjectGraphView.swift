import SwiftUI
import AppKit
import GitKit
import SessionKit
import DesignSystem

/// The commit DAG, drawn as an interactive lane graph beside a column-aligned
/// commit table and the detail inspector of the selected commit.
///
/// Combines visual branch topology, rich search, date categorization (by month/year),
/// agent attributions, and direct web links into a unified commit experience.
struct ProjectGraphView: View {
    @Environment(\.workspaceNavigator) private var navigator
    let sessions: [Session]
    let highlightUnseenCommits: Bool
    let attributionResolver: (any CommitAttributionResolving)?

    @Bindable var viewModel: ProjectGraphViewModel

    init(
        viewModel: ProjectGraphViewModel,
        sessions: [Session] = [],
        highlightUnseenCommits: Bool = true,
        attributionResolver: (any CommitAttributionResolving)? = nil
    ) {
        self._viewModel = Bindable(wrappedValue: viewModel)
        self.sessions = sessions
        self.highlightUnseenCommits = highlightUnseenCommits
        self.attributionResolver = attributionResolver
    }

    private var attributionSignature: String {
        sessions.map { "\($0.id)|\($0.worktree?.branchName ?? "")" }.joined(separator: ",")
    }

    var body: some View {
        SnappingSplit(leadingMin: 460, trailingMin: 360) {
            graphPane
        } trailing: {
            // The detail pane is hosted in AppKit, which does not inherit the
            // SwiftUI environment, so the navigator it reads is handed over.
            CommitDetailView(viewModel: viewModel)
                .environment(\.workspaceNavigator, navigator)
        }
        .task(id: viewModel.repoPath) {
            viewModel.sessions = sessions
            viewModel.attributionResolver = attributionResolver
            viewModel.highlightUnseenCommits = highlightUnseenCommits
            await viewModel.loadIfNeeded()
        }
        .onChange(of: attributionSignature) { _, _ in
            viewModel.sessions = sessions
            Task { await viewModel.loadAttributions() }
        }
        .onChange(of: highlightUnseenCommits) { _, newValue in
            viewModel.highlightUnseenCommits = newValue
        }
        .onDisappear {
            viewModel.markAllAsSeen()
        }
    }

    // MARK: - Graph pane

    private var graphPane: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            if viewModel.isLoading && viewModel.rows.isEmpty {
                loadingState
            } else if let error = viewModel.errorMessage, viewModel.rows.isEmpty {
                ContentUnavailableView(
                    "Couldn’t Draw the Graph",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("ProjectGraph.Error")
            } else if viewModel.rows.isEmpty {
                ContentUnavailableView(
                    "No Commits",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("This repository has no commit history yet.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("ProjectGraph.Empty")
            } else if viewModel.isSearching && viewModel.filteredRows.isEmpty {
                ContentUnavailableView {
                    Label("No Matching Commits", systemImage: "magnifyingglass")
                } description: {
                    Text("No commits match “\(viewModel.searchQuery)”.")
                } actions: {
                    Button("Clear Search") {
                        viewModel.searchQuery = ""
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("ProjectGraph.NoMatches")
            } else if viewModel.filteredRows.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("Nothing on This Branch")
                    } icon: {
                        GitBranchIcon(size: 28)
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }
                } description: {
                    Text("No commits in the loaded window are reachable from “\(viewModel.selectedBranchFilter ?? "")”.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("ProjectGraph.NoBranchMatches")
            } else {
                columnHeader
                commitList
                Divider()
                legendBar
            }
        }
        .flotillaLiquidSurface(FlotillaColors.canvas, glassTintOpacity: FlotillaGlassTint.detail)
    }

    private var loadingState: some View {
        VStack(spacing: FlotillaSpacing.small) {
            ProgressView().controlSize(.small)
            Text("Walking the commit graph…")
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Top bar (Branches & Search)

    private var topBar: some View {
        HStack(spacing: FlotillaSpacing.small) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    GraphBranchChip(
                        title: "All branches",
                        systemImage: "square.stack.3d.up",
                        laneColor: nil,
                        isCurrent: false,
                        isSelected: viewModel.selectedBranchFilter == nil
                    ) {
                        viewModel.selectedBranchFilter = nil
                    }

                    if !viewModel.branches.isEmpty {
                        Rectangle()
                            .fill(FlotillaColors.separator)
                            .frame(width: 1, height: 14)
                            .padding(.horizontal, 2)
                    }

                    ForEach(viewModel.branches, id: \.name) { branch in
                        GraphBranchChip(
                            title: BranchNaming.displayName(for: branch.name),
                            systemImage: branch.isRemote ? "cloud" : "",
                            isBranch: !branch.isRemote,
                            laneColor: viewModel.laneColor(forBranch: branch),
                            isCurrent: branch.isCurrent,
                            isSelected: viewModel.selectedBranchFilter == branch.name
                        ) {
                            viewModel.selectedBranchFilter =
                                viewModel.selectedBranchFilter == branch.name ? nil : branch.name
                        }
                    }
                }
                .padding(.horizontal, FlotillaSpacing.medium)
                .padding(.vertical, FlotillaSpacing.small)
            }

            Spacer(minLength: 0)

            searchField

            if viewModel.newCommitCount > 0 {
                unseenChip
            }

            if viewModel.isLoading {
                ProgressView().controlSize(.small)
            }

            Button {
                Task { await viewModel.reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: FlotillaIconSize.small))
                    .foregroundStyle(FlotillaColors.textSecondary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, FlotillaSpacing.medium)
            .help("Rebuild the graph from disk")
            .accessibilityIdentifier("ProjectGraph.RefreshButton")
        }
        .background(FlotillaColors.surface)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: FlotillaIconSize.small))
                .foregroundStyle(FlotillaColors.textTertiary)
            TextField("Search commits…", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .font(FlotillaTypography.caption)
                .autocorrectionDisabled()
                .textContentType(nil)
                .accessibilityIdentifier("ProjectGraph.SearchField")
            if viewModel.isSearching {
                Button {
                    viewModel.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: FlotillaIconSize.small))
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, FlotillaSpacing.small)
        .padding(.vertical, 4)
        .background(FlotillaColors.surfaceElevated, in: Capsule())
        .frame(maxWidth: 200)
    }

    private var unseenChip: some View {
        Button {
            withAnimation(FlotillaMotion.fast.curve) { viewModel.markAllAsSeen() }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(FlotillaColors.accent)
                    .frame(width: 5, height: 5)
                Text("\(viewModel.newCommitCount) new")
                    .font(FlotillaTypography.caption2.weight(.medium).monospacedDigit())
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(FlotillaColors.accent.opacity(0.16), in: Capsule())
            .foregroundStyle(FlotillaColors.accent)
        }
        .buttonStyle(.plain)
        .help("Commits since you last opened this view — click to mark as seen")
        .accessibilityIdentifier("ProjectGraph.UnseenChip")
    }

    // MARK: - Column header

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: viewModel.gutterWidth, height: 1)

            HStack(spacing: GraphMetrics.columnSpacing) {
                Text("Commit")
                Spacer(minLength: FlotillaSpacing.small)
                Text("Changes")
                    .frame(width: GraphMetrics.statColumn, alignment: .trailing)
                Text("By")
                    .frame(width: GraphMetrics.authorColumn, alignment: .leading)
                Text("When")
                    .frame(width: GraphMetrics.timeColumn, alignment: .trailing)
                Text("ID")
                    .frame(width: GraphMetrics.shaColumn + 18, alignment: .trailing)
            }
            .padding(.horizontal, GraphMetrics.contentInset)
        }
        .font(FlotillaTypography.caption2.weight(.semibold))
        .tracking(FlotillaTypography.Tracking.loose2)
        .textCase(.uppercase)
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(FlotillaColors.textTertiary)
        .padding(.vertical, 5)
        .background(FlotillaColors.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(FlotillaColors.separator).frame(height: 1)
        }
    }

    // MARK: - List

    private var commitList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(viewModel.groupedRows, id: \.group) { group, rows in
                        Section {
                            ForEach(rows) { row in
                                if row.commit.sha == viewModel.firstSeenSHA {
                                    lastReviewedSeparator
                                }
                                GraphCommitRow(
                                    row: row,
                                    gutterWidth: viewModel.gutterWidth,
                                    isSelected: viewModel.selectedSHA == row.commit.sha,
                                    highlightedColorIndex: viewModel.highlightedColorIndex,
                                    webURL: viewModel.webURL(for: row.commit),
                                    attribution: viewModel.attribution(for: row.commit),
                                    isUnpushed: viewModel.isUnpushed(row.commit),
                                    isNew: viewModel.isNew(row.commit)
                                ) {
                                    viewModel.selectedSHA = row.commit.sha
                                }
                                .id(row.commit.sha)
                            }
                        } header: {
                            sectionHeader(group.title, count: rows.count)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("ProjectGraph.List")
            .focusable()
            .onMoveCommand { direction in
                switch direction {
                case .up: move(by: -1, proxy: proxy)
                case .down: move(by: 1, proxy: proxy)
                default: break
                }
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: FlotillaSpacing.small) {
            Text(title)
                .font(FlotillaTypography.caption2.weight(.semibold))
                .tracking(FlotillaTypography.Tracking.loose2)
                .textCase(.uppercase)
                .foregroundStyle(FlotillaColors.textTertiary)
            Spacer()
            Text("\(count)")
                .font(FlotillaTypography.caption2.monospacedDigit())
                .foregroundStyle(FlotillaColors.textTertiary)
        }
        .padding(.horizontal, GraphMetrics.contentInset)
        .padding(.vertical, 4)
        .background(FlotillaColors.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(FlotillaColors.separator.opacity(0.4)).frame(height: 1)
        }
    }

    private var lastReviewedSeparator: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Rectangle()
                .fill(FlotillaColors.accent.opacity(0.35))
                .frame(height: 1)
            Text("Seen before")
                .font(FlotillaTypography.caption2)
                .foregroundStyle(FlotillaColors.textTertiary)
                .fixedSize()
            Rectangle()
                .fill(FlotillaColors.separator)
                .frame(height: 1)
        }
        .padding(.horizontal, GraphMetrics.contentInset)
        .padding(.vertical, FlotillaSpacing.small)
        .accessibilityLabel("Everything below was already seen")
        .accessibilityIdentifier("ProjectGraph.SeenSeparator")
    }

    private func move(by offset: Int, proxy: ScrollViewProxy) {
        guard let sha = viewModel.neighbourSHA(of: viewModel.selectedSHA, offset: offset) else { return }
        viewModel.selectedSHA = sha
        withAnimation(FlotillaMotion.fast.curve) { proxy.scrollTo(sha, anchor: .center) }
    }

    // MARK: - Legend

    private var legendBar: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            GraphLegendItem(shape: .tip, label: "Branch tip")
            GraphLegendItem(shape: .merge, label: "Merge")
            GraphLegendItem(shape: .root, label: "Root")

            Spacer(minLength: FlotillaSpacing.small)

            Text(viewModel.summaryLabel)
                .font(FlotillaTypography.caption2.monospacedDigit())
                .foregroundStyle(FlotillaColors.textTertiary)
                .accessibilityIdentifier("ProjectGraph.Summary")
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, 5)
        .background(FlotillaColors.surface)
    }
}
