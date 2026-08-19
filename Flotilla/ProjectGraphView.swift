import SwiftUI
import AppKit
import GitKit
import SessionKit
import DesignSystem

/// The commit DAG, drawn as a lane graph beside a column-aligned commit table
/// and the detail of whatever is selected.
///
/// Two things make the graph read as a graph rather than a list with dots:
/// the gutter is sized once from the widest row so nothing to its right ever
/// shifts, and selecting a commit lifts its lane out of the rest, which is how
/// you follow a branch across a screenful of history.
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
            graphPane
                .frame(minWidth: 540, idealWidth: 720)
            CommitDetailView(viewModel: historyViewModel)
                .frame(minWidth: 340, idealWidth: 420)
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

    // MARK: - Graph pane

    private var graphPane: some View {
        VStack(spacing: 0) {
            branchBar
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
            } else if viewModel.filteredRows.isEmpty {
                ContentUnavailableView(
                    "Nothing on This Branch",
                    systemImage: "arrow.triangle.branch",
                    description: Text("No commits in the loaded window are reachable from “\(viewModel.selectedBranchFilter ?? "")”.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("ProjectGraph.NoMatches")
            } else {
                columnHeader
                commitList
                Divider()
                legendBar
            }
        }
        .background(FlotillaColors.canvas)
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

    // MARK: - Branch bar

    private var branchBar: some View {
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
                            title: branch.name,
                            systemImage: branch.isRemote ? "cloud" : "arrow.triangle.branch",
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

    // MARK: - Column header

    /// Names the fixed trailing columns. Its only real job is to make the
    /// right-hand alignment look deliberate rather than accidental, so it
    /// shares the row's exact metrics.
    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("Graph")
                .frame(width: viewModel.gutterWidth, alignment: .leading)
                .padding(.leading, GraphMetrics.gutterLeading)

            HStack(spacing: GraphMetrics.columnSpacing) {
                Text("Commit")
                Spacer(minLength: FlotillaSpacing.small)
                Text("Changes")
                    .frame(width: GraphMetrics.statColumn, alignment: .trailing)
                Text("By")
                    .frame(width: GraphMetrics.authorColumn, alignment: .center)
                Text("When")
                    .frame(width: GraphMetrics.timeColumn, alignment: .trailing)
                Text("ID")
                    .frame(width: GraphMetrics.shaColumn, alignment: .trailing)
            }
            .padding(.horizontal, GraphMetrics.contentInset)
        }
        .font(FlotillaTypography.caption2.weight(.semibold))
        .tracking(FlotillaTypography.Tracking.loose2)
        .textCase(.uppercase)
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
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.filteredRows) { row in
                        GraphCommitRow(
                            row: row,
                            gutterWidth: viewModel.gutterWidth,
                            isSelected: viewModel.selectedSHA == row.commit.sha,
                            highlightedColorIndex: viewModel.highlightedColorIndex
                        ) {
                            viewModel.selectedSHA = row.commit.sha
                        }
                        .id(row.commit.sha)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("ProjectGraph.List")
            // Arrow keys walk the graph, which is how anyone reviewing a
            // stretch of history actually moves through it.
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

    private func move(by offset: Int, proxy: ScrollViewProxy) {
        guard let sha = viewModel.neighbourSHA(of: viewModel.selectedSHA, offset: offset) else { return }
        viewModel.selectedSHA = sha
        withAnimation(FlotillaMotion.fast.curve) { proxy.scrollTo(sha, anchor: .center) }
    }

    // MARK: - Legend

    /// Doubles as a status line and a key. The dot vocabulary is only useful
    /// if it's stated somewhere, and the bottom of the graph is where someone
    /// looks once they notice two dots differ.
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

// MARK: - Metrics

/// Shared by the rows and the header, because a table only reads as a table
/// when both agree to the point.
enum GraphMetrics {
    static let rowHeight: CGFloat = 34
    static let laneWidth: CGFloat = 15
    static let gutterLeading: CGFloat = 10
    static let gutterTrailing: CGFloat = 6
    /// Past this the gutter stops growing and the graph clips instead, so a
    /// repository with a dozen live branches can't squeeze the subject column
    /// down to nothing.
    static let maxVisibleLanes = 9

    static let contentInset: CGFloat = 10
    static let columnSpacing: CGFloat = 8
    static let statColumn: CGFloat = 76
    static let authorColumn: CGFloat = 22
    static let timeColumn: CGFloat = 34
    static let shaColumn: CGFloat = 58

    static func gutterWidth(laneCount: Int) -> CGFloat {
        let lanes = CGFloat(min(max(laneCount, 1), maxVisibleLanes))
        return gutterLeading + lanes * laneWidth + gutterTrailing
    }

    static func laneCentre(_ lane: Int) -> CGFloat {
        gutterLeading + CGFloat(lane) * laneWidth + laneWidth / 2
    }
}

// MARK: - Lane palette

/// Eight hues, one per `GitGraphLayout.colorCount` slot, each defined for both
/// appearances — the pastels that read well on the dark canvas turn to mush on
/// white, so light mode gets its own, deeper set.
enum GraphPalette {
    static let lanes: [Color] = [
        dynamic(dark: (0.35, 0.72, 0.98), light: (0.09, 0.45, 0.82)),  // blue
        dynamic(dark: (0.96, 0.45, 0.26), light: (0.83, 0.31, 0.11)),  // orange
        dynamic(dark: (0.29, 0.82, 0.66), light: (0.06, 0.55, 0.44)),  // teal
        dynamic(dark: (0.74, 0.60, 0.99), light: (0.47, 0.30, 0.83)),  // violet
        dynamic(dark: (0.97, 0.76, 0.36), light: (0.71, 0.50, 0.05)),  // amber
        dynamic(dark: (0.98, 0.49, 0.70), light: (0.80, 0.20, 0.48)),  // pink
        dynamic(dark: (0.56, 0.83, 0.44), light: (0.29, 0.55, 0.16)),  // green
        dynamic(dark: (0.60, 0.68, 0.82), light: (0.34, 0.40, 0.52)),  // slate
    ]

    static func lane(_ index: Int) -> Color {
        lanes[abs(index) % lanes.count]
    }

    private static func dynamic(
        dark: (CGFloat, CGFloat, CGFloat),
        light: (CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

// MARK: - Row

private struct GraphCommitRow: View {
    let row: GitGraphRow
    let gutterWidth: CGFloat
    let isSelected: Bool
    /// Lane colour to keep at full strength; everything else recedes. `nil`
    /// leaves the whole graph at full strength.
    let highlightedColorIndex: Int?
    let onSelect: () -> Void

    @State private var isHovering = false

    private var commit: GitCommit { row.commit }

    var body: some View {
        HStack(spacing: 0) {
            GraphLanePainter(
                row: row,
                highlightedColorIndex: highlightedColorIndex,
                isSelected: isSelected
            )
            .frame(width: gutterWidth, height: GraphMetrics.rowHeight)
            .clipped()
            .allowsHitTesting(false)

            content
        }
        .frame(height: GraphMetrics.rowHeight)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            // An accent edge rather than a border: a box around the row would
            // compete with the lane lines running through it.
            Rectangle()
                .fill(FlotillaColors.accent)
                .frame(width: 2)
                .opacity(isSelected ? 1 : 0)
        }
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            withAnimation(FlotillaMotion.fast.curve) { isHovering = hovering }
        }
        .contextMenu { contextMenuItems }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ProjectGraph.Row-\(commit.shortSHA)")
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var rowBackground: Color {
        if isSelected { return FlotillaColors.accent.opacity(0.10) }
        if isHovering { return FlotillaColors.textPrimary.opacity(FlotillaStateOpacity.hover) }
        return .clear
    }

    private var content: some View {
        HStack(spacing: GraphMetrics.columnSpacing) {
            if commit.isMerge {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(GraphPalette.lane(row.colorIndex))
                    .help("Merge of \(commit.parents.count) parents")
            }

            Text(commit.subject)
                .font(FlotillaTypography.body.weight(isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? FlotillaColors.textPrimary : FlotillaColors.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            ForEach(Array(commit.refs.prefix(3).enumerated()), id: \.offset) { _, ref in
                CommitRefChip(ref: ref)
            }

            Spacer(minLength: FlotillaSpacing.small)

            GraphStatCell(stat: commit.stat, fileCount: commit.changedFileCount)
                .frame(width: GraphMetrics.statColumn, alignment: .trailing)

            ProjectMark(
                title: commit.authorName,
                tint: ProjectMark.tint(forKey: commit.authorEmail),
                size: 18
            )
            .frame(width: GraphMetrics.authorColumn, alignment: .center)
            .help(commit.authorName)

            Text(HomeTimestamp.compact(commit.authorDate))
                .font(FlotillaTypography.caption2.monospacedDigit())
                .foregroundStyle(FlotillaColors.textTertiary)
                .frame(width: GraphMetrics.timeColumn, alignment: .trailing)
                .help(commit.authorDate.formatted(date: .abbreviated, time: .shortened))

            Text(commit.shortSHA)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(isHovering ? FlotillaColors.textSecondary : FlotillaColors.textTertiary)
                .frame(width: GraphMetrics.shaColumn, alignment: .trailing)
        }
        .padding(.horizontal, GraphMetrics.contentInset)
    }

    private var accessibilityDescription: String {
        var parts = [commit.subject, "by \(commit.authorName)", HomeTimestamp.compact(commit.authorDate)]
        if commit.isMerge { parts.append("merge commit") }
        if commit.parents.isEmpty { parts.append("root commit") }
        if !commit.refs.isEmpty { parts.append(commit.refs.map(\.name).joined(separator: ", ")) }
        parts.append("lane \(row.lane + 1)")
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Copy SHA") { copy(commit.sha) }
        Button("Copy Short SHA") { copy(commit.shortSHA) }
        Button("Copy Subject") { copy(commit.subject) }
        Button("Copy as “SHA — Subject”") { copy("\(commit.shortSHA) — \(commit.subject)") }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Lane canvas

/// Draws one row's slice of the graph.
///
/// Every edge meets the row boundary vertically at a lane centre, which is
/// what makes independently drawn rows join without seams. The dot is punched
/// out of the line layer rather than painted over it, so the row's own
/// background — hover tint, selection tint — shows through the gap and the
/// halo never has to guess what colour it is sitting on.
private struct GraphLanePainter: View {
    let row: GitGraphRow
    let highlightedColorIndex: Int?
    let isSelected: Bool

    private static let lineWidth: CGFloat = 1.6
    private static let highlightWidth: CGFloat = 2.2
    private static let dimOpacity: CGFloat = 0.32

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let midY = (size.height / 2).rounded() + 0.5
            let dotX = GraphMetrics.laneCentre(row.lane)

            context.drawLayer { layer in
                // Two passes so a highlighted lane is never buried under the
                // lanes it crosses.
                for segment in ordered(dimmedFirst: true) {
                    stroke(segment, in: &layer, midY: midY, height: size.height)
                }

                layer.blendMode = .destinationOut
                layer.fill(
                    Path(ellipseIn: CGRect(
                        x: dotX - haloRadius, y: midY - haloRadius,
                        width: haloRadius * 2, height: haloRadius * 2
                    )),
                    with: .color(.black)
                )
            }

            drawDot(in: &context, at: CGPoint(x: dotX, y: midY))
        }
        .drawingGroup(opaque: false)
    }

    // MARK: Segments

    /// Pass-throughs first (they are backdrop), then dimmed lanes, then the
    /// highlighted lane on top.
    private func ordered(dimmedFirst: Bool) -> [GitGraphSegment] {
        let rank = { (segment: GitGraphSegment) -> Int in
            let isHighlighted = highlightedColorIndex == segment.colorIndex
            if segment.kind == .passThrough { return isHighlighted ? 2 : 0 }
            return isHighlighted ? 3 : 1
        }
        return row.segments.sorted { rank($0) < rank($1) }
    }

    private func stroke(
        _ segment: GitGraphSegment,
        in context: inout GraphicsContext,
        midY: CGFloat,
        height: CGFloat
    ) {
        let from = GraphMetrics.laneCentre(segment.fromLane)
        let to = GraphMetrics.laneCentre(segment.toLane)
        var path = Path()

        switch segment.kind {
        case .passThrough:
            path.move(to: CGPoint(x: from, y: 0))
            path.addLine(to: CGPoint(x: to, y: height))
        case .incoming:
            path.move(to: CGPoint(x: from, y: 0))
            if segment.isDiagonal {
                // Control points stay on their own lane so the curve leaves
                // the row edge vertically and arrives at the dot vertically —
                // that's what makes the join with the row above invisible.
                path.addCurve(
                    to: CGPoint(x: to, y: midY),
                    control1: CGPoint(x: from, y: midY * 0.45),
                    control2: CGPoint(x: to, y: midY * 0.55)
                )
            } else {
                path.addLine(to: CGPoint(x: to, y: midY))
            }
        case .outgoing:
            path.move(to: CGPoint(x: from, y: midY))
            if segment.isDiagonal {
                let span = height - midY
                path.addCurve(
                    to: CGPoint(x: to, y: height),
                    control1: CGPoint(x: from, y: midY + span * 0.45),
                    control2: CGPoint(x: to, y: midY + span * 0.55)
                )
            } else {
                path.addLine(to: CGPoint(x: to, y: height))
            }
        }

        let isHighlighted = highlightedColorIndex == segment.colorIndex
        let dims = highlightedColorIndex != nil && !isHighlighted
        context.stroke(
            path,
            with: .color(GraphPalette.lane(segment.colorIndex).opacity(dims ? Self.dimOpacity : 1)),
            style: StrokeStyle(
                lineWidth: isHighlighted ? Self.highlightWidth : Self.lineWidth,
                lineCap: .round,
                lineJoin: .round
            )
        )
    }

    // MARK: Dot

    private var commit: GitCommit { row.commit }
    private var isTip: Bool { !commit.refs.isEmpty }
    private var isRoot: Bool { commit.parents.isEmpty }

    private var dotRadius: CGFloat {
        if isTip { return 5 }
        if commit.isMerge { return 4.5 }
        return 3.75
    }

    private var haloRadius: CGFloat { dotRadius + 2.4 }

    /// Shape carries the meaning alongside colour — a hollow ring for a merge,
    /// a haloed disc for a branch tip, a ringed disc for a root — so the graph
    /// stays readable without relying on hue alone.
    private func drawDot(in context: inout GraphicsContext, at centre: CGPoint) {
        let color = GraphPalette.lane(row.colorIndex)
        let dims = highlightedColorIndex != nil && highlightedColorIndex != row.colorIndex
        let tint = color.opacity(dims ? 0.45 : 1)

        func circle(_ radius: CGFloat) -> Path {
            Path(ellipseIn: CGRect(
                x: centre.x - radius, y: centre.y - radius,
                width: radius * 2, height: radius * 2
            ))
        }

        if isTip {
            context.stroke(circle(dotRadius + 3), with: .color(color.opacity(dims ? 0.12 : 0.28)), lineWidth: 2)
        }

        if commit.isMerge {
            context.stroke(circle(dotRadius - 0.9), with: .color(tint), lineWidth: 2)
        } else {
            context.fill(circle(dotRadius), with: .color(tint))
            if isRoot {
                context.stroke(circle(dotRadius + 2.2), with: .color(tint.opacity(0.5)), lineWidth: 1)
            }
        }

        if isSelected {
            context.stroke(circle(dotRadius + 4.2), with: .color(FlotillaColors.accent), lineWidth: 1.5)
        }
    }
}

// MARK: - Small parts

/// Additions and deletions as one right-aligned pair, so the numbers stack
/// into a column instead of drifting with each row's digit count.
private struct GraphStatCell: View {
    let stat: GitDiffStat
    let fileCount: Int

    var body: some View {
        HStack(spacing: 4) {
            if stat.isEmpty {
                Text("—")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textTertiary.opacity(0.6))
            } else {
                Text("+\(stat.additions)")
                    .foregroundStyle(FlotillaColors.diffAdded)
                Text("−\(stat.deletions)")
                    .foregroundStyle(FlotillaColors.diffRemoved)
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .help(stat.isEmpty ? "No line changes recorded" : "\(fileCount) file\(fileCount == 1 ? "" : "s") changed")
    }
}

private struct GraphBranchChip: View {
    let title: String
    let systemImage: String
    /// The colour this branch's tip occupies in the graph, which is what ties
    /// the chip to the lane it filters to.
    let laneColor: Color?
    let isCurrent: Bool
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let laneColor {
                    Circle()
                        .fill(laneColor)
                        .frame(width: 6, height: 6)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 8, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 10, weight: isCurrent ? .semibold : .medium, design: .monospaced))
                    .lineLimit(1)
                if isCurrent {
                    Image(systemName: "location.fill")
                        .font(.system(size: 7))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(background, in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    isSelected ? FlotillaColors.accent.opacity(0.55) : Color.clear,
                    lineWidth: 1
                )
            }
            .foregroundStyle(isSelected ? FlotillaColors.accent : FlotillaColors.textSecondary)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isSelected ? "Showing only \(title) — click to clear" : "Show only commits reachable from \(title)")
    }

    private var background: Color {
        if isSelected { return FlotillaColors.accent.opacity(FlotillaStateOpacity.selected) }
        if isHovering { return FlotillaColors.surfaceElevated }
        return FlotillaColors.surfaceElevated.opacity(0.6)
    }
}

private struct GraphLegendItem: View {
    enum Shape { case tip, merge, root }

    let shape: Shape
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            glyph
                .frame(width: 12, height: 12)
            Text(label)
                .font(FlotillaTypography.caption2)
                .foregroundStyle(FlotillaColors.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var glyph: some View {
        switch shape {
        case .tip:
            Circle()
                .fill(FlotillaColors.textTertiary)
                .frame(width: 7, height: 7)
                .overlay {
                    Circle()
                        .strokeBorder(FlotillaColors.textTertiary.opacity(0.35), lineWidth: 1.5)
                        .frame(width: 12, height: 12)
                }
        case .merge:
            Circle()
                .strokeBorder(FlotillaColors.textTertiary, lineWidth: 1.6)
                .frame(width: 8, height: 8)
        case .root:
            Circle()
                .fill(FlotillaColors.textTertiary)
                .frame(width: 6, height: 6)
                .overlay {
                    Circle()
                        .strokeBorder(FlotillaColors.textTertiary.opacity(0.5), lineWidth: 1)
                        .frame(width: 11, height: 11)
                }
        }
    }
}

// MARK: - ViewModel

@Observable
@MainActor
final class ProjectGraphViewModel {
    /// One `--all` window. Deep enough to reach the merge base of anything
    /// still in flight, shallow enough that the layout stays instantaneous.
    static let windowSize = 500

    let repoPath: URL
    private let gitService: any GitServiceProtocol

    private(set) var rows: [GitGraphRow] = []
    private(set) var filteredRows: [GitGraphRow] = []
    private(set) var branches: [GitBranch] = []

    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// The commits behind `rows`, kept so a branch filter can re-run the
    /// layout over a subset rather than punching holes in the finished graph.
    private var commits: [GitCommit] = []
    private var colorIndexBySHA: [String: Int] = [:]

    var selectedBranchFilter: String? {
        didSet { if oldValue != selectedBranchFilter { recomputeFilteredRows() } }
    }

    var selectedSHA: String?

    init(repoPath: URL, gitService: any GitServiceProtocol) {
        self.repoPath = repoPath
        self.gitService = gitService
    }

    // MARK: Derived

    /// One width for the whole graph, taken from its widest row. Sizing the
    /// gutter per row is what used to make every column to its right shuffle
    /// sideways as the graph opened and closed.
    var gutterWidth: CGFloat {
        GraphMetrics.gutterWidth(laneCount: GitGraphLayout.laneCount(of: filteredRows))
    }

    /// The lane the selection sits on, which the rows use to lift that branch
    /// out of the rest of the graph.
    var highlightedColorIndex: Int? {
        guard let selectedSHA else { return nil }
        return colorIndexBySHA[selectedSHA]
    }

    func laneColor(forBranch branch: GitBranch) -> Color? {
        colorIndexBySHA[branch.tipSHA].map(GraphPalette.lane)
    }

    var summaryLabel: String {
        let count = filteredRows.count
        let lanes = GitGraphLayout.laneCount(of: filteredRows)
        let commitWord = count == 1 ? "commit" : "commits"
        let laneWord = lanes == 1 ? "lane" : "lanes"
        return "\(count) \(commitWord) · \(lanes) \(laneWord) · \(branches.count) branches"
    }

    func neighbourSHA(of sha: String?, offset: Int) -> String? {
        guard !filteredRows.isEmpty else { return nil }
        guard let sha, let index = filteredRows.firstIndex(where: { $0.commit.sha == sha }) else {
            return filteredRows.first?.commit.sha
        }
        let target = index + offset
        guard filteredRows.indices.contains(target) else { return nil }
        return filteredRows[target].commit.sha
    }

    // MARK: Loading

    func reload() async {
        isLoading = true
        defer { isLoading = false }

        do {
            async let logTask = gitService.logGraph(at: repoPath, maxCount: Self.windowSize)
            async let branchesTask = gitService.branches(at: repoPath)
            let (loaded, branchList) = try await (logTask, branchesTask)

            commits = loaded
            rows = GitGraphLayout.rows(for: loaded)
            colorIndexBySHA = Dictionary(
                rows.map { ($0.commit.sha, $0.colorIndex) },
                uniquingKeysWith: { first, _ in first }
            )
            branches = Self.ordered(branchList)
            errorMessage = nil
            recomputeFilteredRows()

            if selectedSHA == nil || colorIndexBySHA[selectedSHA!] == nil {
                selectedSHA = rows.first?.commit.sha
            }
        } catch {
            errorMessage = error.localizedDescription
            commits = []
            rows = []
            filteredRows = []
            branches = []
            colorIndexBySHA = [:]
        }
    }

    // MARK: Filtering

    /// Filters by *reachability*, then lays the survivors out again.
    ///
    /// Keeping the original rows and hiding the rest looked plausible but drew
    /// nonsense: a row's segments name lanes belonging to rows that are no
    /// longer on screen, so edges pointed at empty space. Re-running the
    /// layout over the ancestor set is the only way a filtered graph is still
    /// a graph.
    private func recomputeFilteredRows() {
        guard let filter = selectedBranchFilter else {
            filteredRows = rows
            return
        }
        guard let tip = tipSHA(forBranch: filter) else {
            filteredRows = rows
            return
        }

        let byS = Dictionary(commits.map { ($0.sha, $0) }, uniquingKeysWith: { first, _ in first })
        var reachable: Set<String> = []
        var frontier = [tip]
        while let sha = frontier.popLast() {
            guard reachable.insert(sha).inserted, let commit = byS[sha] else { continue }
            frontier.append(contentsOf: commit.parents)
        }
        filteredRows = GitGraphLayout.rows(for: commits.filter { reachable.contains($0.sha) })
    }

    private func tipSHA(forBranch name: String) -> String? {
        if let branch = branches.first(where: { $0.name == name }) { return branch.tipSHA }
        // A ref decoration without a matching `for-each-ref` entry still
        // identifies a tip — worth honouring rather than showing everything.
        return commits.first { $0.refs.contains { $0.name == name } }?.sha
    }

    /// Current branch first, then locals, then remotes — the order someone
    /// scanning the chip row expects to find them in.
    private static func ordered(_ branches: [GitBranch]) -> [GitBranch] {
        branches.sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            if lhs.isRemote != rhs.isRemote { return !lhs.isRemote }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
