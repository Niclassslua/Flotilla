import SwiftUI
import AppKit
import GitKit
import SessionKit
import DesignSystem

/// Git commit graph view featuring lane visualization with bezier edge routing,
/// branch filter chips, and commit details inspector in a trailing split.
struct ProjectGraphView: View {
    let repoPath: URL
    let gitService: any GitServiceProtocol
    let sessions: [Session]

    @State private var viewModel: ProjectGraphViewModel
    @State private var historyViewModel: ProjectHistoryViewModel

    init(
        repoPath: URL,
        gitService: any GitServiceProtocol,
        sessions: [Session] = []
    ) {
        self.repoPath = repoPath
        self.gitService = gitService
        self.sessions = sessions
        self._viewModel = State(initialValue: ProjectGraphViewModel(repoPath: repoPath, gitService: gitService))
        self._historyViewModel = State(initialValue: ProjectHistoryViewModel(repoPath: repoPath, gitService: gitService))
    }

    var body: some View {
        HSplitView {
            graphMainSection
                .frame(minWidth: 480, idealWidth: 640)
            CommitDetailView(viewModel: historyViewModel)
                .frame(minWidth: 320, idealWidth: 400)
        }
        .task(id: repoPath) {
            await viewModel.reload()
            historyViewModel.sessions = sessions
            if let firstSHA = viewModel.selectedSHA {
                historyViewModel.selectedSHA = firstSHA
            }
        }
        .onChange(of: viewModel.selectedSHA) { _, newSHA in
            if let newSHA {
                historyViewModel.selectedSHA = newSHA
            }
        }
    }

    // MARK: - Graph Main Section

    private var graphMainSection: some View {
        VStack(spacing: 0) {
            branchChipRow
            Divider()

            if viewModel.isLoading && viewModel.rows.isEmpty {
                ProgressView("Building commit graph…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.errorMessage, viewModel.rows.isEmpty {
                ContentUnavailableView(
                    "Failed to Load Graph",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.rows.isEmpty {
                ContentUnavailableView(
                    "No Commits",
                    systemImage: "circle.dashed",
                    description: Text("This repository has no commit history yet.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.filteredRows, id: \.commit.sha) { row in
                            GraphCommitRow(
                                row: row,
                                isSelected: viewModel.selectedSHA == row.commit.sha,
                                onSelect: {
                                    viewModel.selectedSHA = row.commit.sha
                                }
                            )
                        }
                    }
                    .padding(.vertical, FlotillaSpacing.xSmall)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(FlotillaColors.canvas)
    }

    // MARK: - Branch Chip Row

    private var branchChipRow: some View {
        HStack(spacing: FlotillaSpacing.small) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button {
                        viewModel.selectedBranchFilter = nil
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "circle.grid.2x1.left.filled")
                                .font(.system(size: 8))
                            Text("All Branches")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            viewModel.selectedBranchFilter == nil ? FlotillaColors.accent.opacity(0.18) : FlotillaColors.surfaceElevated,
                            in: Capsule()
                        )
                        .foregroundStyle(viewModel.selectedBranchFilter == nil ? FlotillaColors.accent : FlotillaColors.textSecondary)
                    }
                    .buttonStyle(.plain)

                    ForEach(viewModel.branches, id: \.name) { branch in
                        Button {
                            if viewModel.selectedBranchFilter == branch.name {
                                viewModel.selectedBranchFilter = nil
                            } else {
                                viewModel.selectedBranchFilter = branch.name
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: branch.isRemote ? "cloud" : "arrow.triangle.branch")
                                    .font(.system(size: 8))
                                Text(branch.name)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                viewModel.selectedBranchFilter == branch.name ? FlotillaColors.accent.opacity(0.18) : FlotillaColors.surfaceElevated,
                                in: Capsule()
                            )
                            .foregroundStyle(viewModel.selectedBranchFilter == branch.name ? FlotillaColors.accent : FlotillaColors.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, FlotillaSpacing.medium)
                .padding(.vertical, FlotillaSpacing.small)
            }

            Spacer(minLength: 0)

            Button {
                Task { await viewModel.reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: FlotillaIconSize.small))
            }
            .buttonStyle(.plain)
            .padding(.trailing, FlotillaSpacing.medium)
            .help("Refresh graph")
        }
        .background(FlotillaColors.surface)
    }
}

// MARK: - Graph Row

private struct GraphCommitRow: View {
    let row: GitGraphRow
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    private static let rowHeight: CGFloat = 30
    private static let laneWidth: CGFloat = 14
    private static let dotRadius: CGFloat = 3.5

    var body: some View {
        HStack(spacing: 6) {
            // Lane visualization canvas
            laneCanvas
                .frame(width: max(CGFloat(row.laneCount) * Self.laneWidth + 8, 24), height: Self.rowHeight)

            Text(row.commit.shortSHA)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(FlotillaColors.textTertiary)
                .frame(width: 58, alignment: .leading)

            Text(row.commit.subject)
                .font(FlotillaTypography.body)
                .foregroundStyle(FlotillaColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: FlotillaSpacing.small)

            ForEach(Array(row.commit.refs.prefix(3).enumerated()), id: \.offset) { _, ref in
                CommitRefChip(ref: ref)
            }

            Text(HomeTimestamp.compact(row.commit.authorDate))
                .font(FlotillaTypography.caption2.monospacedDigit())
                .foregroundStyle(FlotillaColors.textTertiary)
                .frame(minWidth: 28, alignment: .trailing)
        }
        .padding(.horizontal, FlotillaSpacing.small)
        .frame(height: Self.rowHeight)
        .background(
            isSelected
                ? FlotillaColors.accent.opacity(0.12)
                : (isHovering ? FlotillaColors.surfaceElevated.opacity(0.5) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }

    private var laneCanvas: some View {
        Canvas { context, size in
            let midY = size.height / 2
            let dotX = CGFloat(row.lane) * Self.laneWidth + Self.laneWidth / 2

            // 1. Draw segments
            for segment in row.segments {
                let fromX = CGFloat(segment.fromLane) * Self.laneWidth + Self.laneWidth / 2
                let toX = CGFloat(segment.toLane) * Self.laneWidth + Self.laneWidth / 2
                let color = Self.laneColor(segment.colorIndex)

                var path = Path()
                switch segment.kind {
                case .passThrough:
                    path.move(to: CGPoint(x: fromX, y: 0))
                    path.addLine(to: CGPoint(x: toX, y: size.height))
                case .branchOut:
                    // Starts from current commit at midY, curves down to toLane at bottom
                    path.move(to: CGPoint(x: fromX, y: midY))
                    path.addCurve(
                        to: CGPoint(x: toX, y: size.height),
                        control1: CGPoint(x: fromX, y: midY + (size.height - midY) * 0.5),
                        control2: CGPoint(x: toX, y: midY + (size.height - midY) * 0.5)
                    )
                case .mergeIn:
                    // Starts from top at fromLane, curves into toLane at midY
                    path.move(to: CGPoint(x: fromX, y: 0))
                    path.addCurve(
                        to: CGPoint(x: toX, y: midY),
                        control1: CGPoint(x: fromX, y: midY * 0.5),
                        control2: CGPoint(x: toX, y: midY * 0.5)
                    )
                }

                context.stroke(path, with: .color(color), lineWidth: 1.5)
            }

            // 2. Draw commit dot
            let dotColor = Self.laneColor(row.colorIndex)
            let dotRect = CGRect(
                x: dotX - Self.dotRadius,
                y: midY - Self.dotRadius,
                width: Self.dotRadius * 2,
                height: Self.dotRadius * 2
            )
            context.fill(Path(ellipseIn: dotRect), with: .color(dotColor))
            context.stroke(Path(ellipseIn: dotRect), with: .color(FlotillaColors.canvas), lineWidth: 1)
        }
    }

    static func laneColor(_ index: Int) -> Color {
        let palette = ProjectMark.tints
        return palette[abs(index) % palette.count]
    }
}

// MARK: - ViewModel

@Observable
@MainActor
final class ProjectGraphViewModel {
    let repoPath: URL
    private let gitService: any GitServiceProtocol

    private(set) var rows: [GitGraphRow] = []
    private(set) var branches: [GitBranch] = []
    var selectedBranchFilter: String?
    var selectedSHA: String?

    private(set) var isLoading = false
    private(set) var errorMessage: String?

    init(repoPath: URL, gitService: any GitServiceProtocol) {
        self.repoPath = repoPath
        self.gitService = gitService
    }

    var filteredRows: [GitGraphRow] {
        guard let filter = selectedBranchFilter else { return rows }
        // Filter rows by commits matching the selected branch name or tip
        return rows.filter { row in
            row.commit.refs.contains { $0.name == filter } || row.commit.sha.hasPrefix(filter)
        }
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }

        do {
            async let logTask = gitService.logGraph(at: repoPath, maxCount: 500)
            async let branchesTask = gitService.branches(at: repoPath)

            let (commits, branchList) = try await (logTask, branchesTask)

            rows = GitGraphLayout.rows(for: commits)
            branches = branchList
            errorMessage = nil

            if selectedSHA == nil || !rows.contains(where: { $0.commit.sha == selectedSHA }) {
                selectedSHA = rows.first?.commit.sha
            }
        } catch {
            errorMessage = error.localizedDescription
            rows = []
            branches = []
        }
    }
}
