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
    let repoPath: URL
    let gitService: any GitServiceProtocol
    let sessions: [Session]
    let highlightUnseenCommits: Bool

    @State private var viewModel: ProjectGraphViewModel

    init(
        repoPath: URL,
        gitService: any GitServiceProtocol,
        sessions: [Session] = [],
        highlightUnseenCommits: Bool = true
    ) {
        self.repoPath = repoPath
        self.gitService = gitService
        self.sessions = sessions
        self.highlightUnseenCommits = highlightUnseenCommits
        self._viewModel = State(initialValue: ProjectGraphViewModel(repoPath: repoPath, gitService: gitService))
    }

    private var attributionSignature: String {
        sessions.map { "\($0.id)|\($0.worktree?.branchName ?? "")" }.joined(separator: ",")
    }

    var body: some View {
        HSplitView {
            graphPane
                .frame(minWidth: 540, idealWidth: 720)
            CommitDetailView(viewModel: viewModel)
                .frame(minWidth: 360, idealWidth: 460)
        }
        .task(id: repoPath) {
            viewModel.sessions = sessions
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
                ContentUnavailableView(
                    "Nothing on This Branch",
                    systemImage: "arrow.triangle.branch",
                    description: Text("No commits in the loaded window are reachable from “\(viewModel.selectedBranchFilter ?? "")”.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("ProjectGraph.NoBranchMatches")
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
                    .frame(width: GraphMetrics.authorColumn, alignment: .center)
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

// MARK: - Metrics

enum GraphMetrics {
    static let rowHeight: CGFloat = 34
    static let laneWidth: CGFloat = 15
    static let gutterLeading: CGFloat = 10
    static let gutterTrailing: CGFloat = 6
    static let maxVisibleLanes = 9

    static let contentInset: CGFloat = 10
    static let columnSpacing: CGFloat = 8
    static let statColumn: CGFloat = 88
    static let authorColumn: CGFloat = 22
    static let timeColumn: CGFloat = 44
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

// MARK: - Date Grouping

/// Recency buckets for timeline section headers (Today, Yesterday, Earlier This Week, Month Year).
enum CommitDateGroup: Hashable {
    case today
    case yesterday
    case thisWeek
    case month(year: Int, month: Int)

    init(for date: Date) {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            self = .today
        } else if calendar.isDateInYesterday(date) {
            self = .yesterday
        } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()), date > weekAgo {
            self = .thisWeek
        } else {
            let parts = calendar.dateComponents([.year, .month], from: date)
            self = .month(year: parts.year ?? 0, month: parts.month ?? 0)
        }
    }

    var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "Earlier This Week"
        case .month(let year, let month):
            var components = DateComponents()
            components.year = year
            components.month = month
            guard let date = Calendar.current.date(from: components) else { return "Earlier" }
            return date.formatted(.dateTime.month(.wide).year())
        }
    }
}

// MARK: - Row

private struct GraphCommitRow: View {
    let row: GitGraphRow
    let gutterWidth: CGFloat
    let isSelected: Bool
    let highlightedColorIndex: Int?
    let webURL: URL?
    let attribution: CommitAttribution?
    let isUnpushed: Bool
    let isNew: Bool
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
            Text(commit.subject)
                .font(FlotillaTypography.body.weight(isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? FlotillaColors.textPrimary : FlotillaColors.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            if isNew {
                CommitRefChip(text: "NEW", systemImage: "sparkle", tint: FlotillaColors.accent)
            }
            if isUnpushed {
                CommitRefChip(text: "unpushed", systemImage: "arrow.up.circle", tint: FlotillaColors.accent)
            }
            ForEach(Array(commit.refs.prefix(3).enumerated()), id: \.offset) { _, ref in
                CommitRefChip(ref: ref)
            }

            Spacer(minLength: FlotillaSpacing.small)

            GraphStatCell(stat: commit.stat, fileCount: commit.changedFileCount)
                .frame(minWidth: GraphMetrics.statColumn, alignment: .trailing)

            authorIdentity
                .frame(width: GraphMetrics.authorColumn, alignment: .center)

            Text(HomeTimestamp.compact(commit.authorDate))
                .font(FlotillaTypography.caption2.monospacedDigit())
                .foregroundStyle(FlotillaColors.textTertiary)
                .frame(width: GraphMetrics.timeColumn, alignment: .trailing)
                .help(commit.authorDate.formatted(date: .abbreviated, time: .shortened))

            HStack(spacing: 4) {
                Text(commit.shortSHA)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isHovering ? FlotillaColors.textSecondary : FlotillaColors.textTertiary)

                if let webURL {
                    Link(destination: webURL) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10))
                            .foregroundStyle(isHovering ? FlotillaColors.accent : FlotillaColors.textTertiary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Open commit on the web")
                    .accessibilityIdentifier("ProjectGraph.RowWebLink-\(commit.shortSHA)")
                }
            }
            .frame(width: GraphMetrics.shaColumn + 18, alignment: .trailing)
        }
        .padding(.horizontal, GraphMetrics.contentInset)
    }

    @ViewBuilder
    private var authorIdentity: some View {
        if let attribution {
            ProviderLogo(agent: attribution.agent)
                .frame(width: 16, height: 16)
                .help("\(attribution.displayName) (\(attribution.agent.displayName)) — \(attribution.source.explanation)")
        } else {
            ProjectMark(
                title: commit.authorName,
                tint: ProjectMark.tint(forKey: commit.authorEmail),
                size: 18
            )
            .help(commit.authorName)
        }
    }

    private var accessibilityDescription: String {
        var parts = [commit.subject]
        if let attribution {
            parts.append("by \(attribution.agent.displayName), \(attribution.source.explanation)")
        } else {
            parts.append("by \(commit.authorName)")
        }
        parts.append(HomeTimestamp.compact(commit.authorDate))
        if isNew { parts.append("new since your last visit") }
        if commit.isMerge { parts.append("merge commit") }
        if isUnpushed { parts.append("not yet pushed") }
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
        if let webURL {
            Divider()
            Link("Open on the Web", destination: webURL)
            Button("Copy Link") { copy(webURL.absoluteString) }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Lane canvas

private struct GraphLanePainter: View {
    let row: GitGraphRow
    let highlightedColorIndex: Int?
    let isSelected: Bool

    private static let lineWidth: CGFloat = 1.6
    private static let highlightWidth: CGFloat = 2.2
    private static let dimOpacity: CGFloat = 0.32

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let midY = size.height / 2
            let dotX = GraphMetrics.laneCentre(row.lane)

            context.drawLayer { layer in
                for segment in orderedSegments {
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
    }

    private var orderedSegments: [GitGraphSegment] {
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

    private var commit: GitCommit { row.commit }
    private var isTip: Bool { !commit.refs.isEmpty }
    private var isRoot: Bool { commit.parents.isEmpty }

    private var dotRadius: CGFloat {
        if isTip { return 5 }
        if commit.isMerge { return 4.5 }
        return 3.75
    }

    private var haloRadius: CGFloat { dotRadius + 2.4 }

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

private struct GraphStatCell: View {
    let stat: GitDiffStat
    let fileCount: Int

    var body: some View {
        HStack(spacing: 3.5) {
            if stat.isEmpty {
                Text("—")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textTertiary.opacity(0.6))
            } else {
                Text("+\(stat.additions.formatted())")
                    .foregroundStyle(FlotillaColors.diffAdded)
                Text("−\(stat.deletions.formatted())")
                    .foregroundStyle(FlotillaColors.diffRemoved)
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .help(stat.isEmpty ? "No line changes recorded" : "\(fileCount) file\(fileCount == 1 ? "" : "s") changed (\(stat.additions.formatted()) additions, \(stat.deletions.formatted()) deletions)")
    }
}

private struct GraphBranchChip: View {
    let title: String
    let systemImage: String
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
    enum Marker { case tip, merge, root }

    let shape: Marker
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

// MARK: - Attribution Model

struct CommitAttribution: Equatable {
    enum Source: Equatable {
        case trailer
        case sessionBranch
        case authorIdentity

        var explanation: String {
            switch self {
            case .trailer: return "Recorded in the commit by Flotilla"
            case .sessionBranch: return "Only on this session's branch"
            case .authorIdentity: return "Committed under the agent's git identity"
            }
        }
    }

    let agent: AgentKind
    let sessionID: UUID?
    let sessionTitle: String?
    let branchName: String?
    let source: Source

    var displayName: String { sessionTitle ?? agent.displayName }
}

extension AgentKind {
    static func inferredFromGitIdentity(name: String, email: String) -> AgentKind? {
        let name = name.lowercased()
        let email = email.lowercased()
        let domain = email.split(separator: "@").last.map(String.init) ?? ""

        if domain == "anthropic.com" || name == "claude code" || name == "claude" {
            return .claudeCode
        }
        if name == "codex" || name == "codex cli" || email.hasPrefix("codex@") {
            return .codexCLI
        }
        if name == "opencode" || domain == "opencode.ai" || email.hasPrefix("opencode@") {
            return .openCode
        }
        if name == "antigravity" || email.hasPrefix("antigravity@") {
            return .antigravity
        }
        return nil
    }

    static func fromTrailerValue(_ value: String) -> AgentKind? {
        AgentKind(rawValue: value.trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - Ref Chip

/// Capsule chip for a ref decoration — branch, remote, or tag.
struct CommitRefChip: View {
    let text: String
    let systemImage: String
    let tint: Color

    init(text: String, systemImage: String, tint: Color) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    init(ref: GitCommitRef) {
        self.text = ref.name
        switch ref.kind {
        case .head:
            self.systemImage = "location.fill"
            self.tint = FlotillaColors.accent
        case .localBranch:
            self.systemImage = "arrow.triangle.branch"
            self.tint = FlotillaColors.accent
        case .remoteBranch:
            self.systemImage = "cloud"
            self.tint = FlotillaColors.textTertiary
        case .tag:
            self.systemImage = "tag"
            self.tint = FlotillaColors.statusReady
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 8, weight: .semibold))
            Text(text)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(tint.opacity(0.14), in: Capsule())
        .foregroundStyle(tint)
        .fixedSize()
    }
}

// MARK: - ViewModel

@Observable
@MainActor
final class ProjectGraphViewModel {
    static let windowSize = 500
    static let pageSize = 100

    let repoPath: URL
    private let gitService: any GitServiceProtocol

    private(set) var commits: [GitCommit] = []
    private(set) var rows: [GitGraphRow] = []
    private(set) var filteredRows: [GitGraphRow] = []
    private(set) var branches: [GitBranch] = []
    private(set) var availableRefs: [String] = []
    private(set) var remoteURL: String?
    private(set) var mainWorktreeBranch: String?
    private(set) var unpushedSHAs: Set<String> = []

    var sessions: [Session] = []
    private(set) var attributions: [String: CommitAttribution] = [:]

    var highlightUnseenCommits = true {
        didSet { if oldValue != highlightUnseenCommits { recomputeNewCommits() } }
    }
    private(set) var newCommitSHAs: Set<String> = []
    private var previouslySeenSHA: String?
    private var hasCapturedSeenMarker = false

    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = false
    private(set) var errorMessage: String?

    private var colorIndexBySHA: [String: Int] = [:]

    var selectedBranchFilter: String? {
        didSet { if oldValue != selectedBranchFilter { recomputeFilteredRows() } }
    }

    var selectedRef: String? {
        get { selectedBranchFilter }
        set { selectedBranchFilter = newValue }
    }

    var searchQuery: String = "" {
        didSet { if oldValue != searchQuery { recomputeFilteredRows() } }
    }

    var selectedSHA: String? {
        didSet { if oldValue != selectedSHA { Task { await loadDetail() } } }
    }

    private(set) var detail: GitCommitDetail?
    private(set) var isLoadingDetail = false
    private var detailCache: [String: GitCommitDetail] = [:]

    init(repoPath: URL, gitService: any GitServiceProtocol) {
        self.repoPath = repoPath
        self.gitService = gitService
    }

    // MARK: Derived

    var gutterWidth: CGFloat {
        GraphMetrics.gutterWidth(laneCount: GitGraphLayout.laneCount(of: filteredRows))
    }

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

    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var filteredCommits: [GitCommit] {
        filteredRows.map(\.commit)
    }

    var groupedRows: [(group: CommitDateGroup, rows: [GitGraphRow])] {
        var order: [CommitDateGroup] = []
        var buckets: [CommitDateGroup: [GitGraphRow]] = [:]
        for row in filteredRows {
            let group = CommitDateGroup(for: row.commit.authorDate)
            if buckets[group] == nil { order.append(group) }
            buckets[group, default: []].append(row)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var groupedCommits: [(group: CommitDateGroup, commits: [GitCommit])] {
        groupedRows.map { ($0.group, $0.rows.map(\.commit)) }
    }

    func webURL(for commit: GitCommit) -> URL? {
        guard let remoteURL else { return nil }
        return GitService.webURL(forRemote: remoteURL, commitSHA: commit.sha)
    }

    func isUnpushed(_ commit: GitCommit) -> Bool { unpushedSHAs.contains(commit.sha) }

    func attribution(for commit: GitCommit) -> CommitAttribution? { attributions[commit.sha] }

    func isNew(_ commit: GitCommit) -> Bool { newCommitSHAs.contains(commit.sha) }

    var newCommitCount: Int { newCommitSHAs.count }

    var firstSeenSHA: String? {
        guard !newCommitSHAs.isEmpty else { return nil }
        return filteredRows.first { !newCommitSHAs.contains($0.commit.sha) }?.commit.sha
    }

    func isTip(_ commit: GitCommit) -> Bool { commit.sha == commits.first?.sha }

    // MARK: Loading

    func loadIfNeeded() async {
        guard commits.isEmpty, !isLoading else { return }
        await reload()
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }

        await loadRefsAndRemote()

        do {
            async let logTask = gitService.log(at: repoPath, ref: selectedBranchFilter, skip: 0, maxCount: Self.pageSize)
            async let graphTask = gitService.logGraph(at: repoPath, maxCount: Self.pageSize)
            async let branchesTask = gitService.branches(at: repoPath)
            async let unpushedTask = gitService.unpushedSHAs(at: repoPath, ref: selectedBranchFilter)
            let (page, graphPage, branchList) = try await (logTask, graphTask, branchesTask)
            let loaded = graphPage.isEmpty ? page : graphPage

            commits = loaded
            rows = GitGraphLayout.rows(for: loaded)
            colorIndexBySHA = Dictionary(
                rows.map { ($0.commit.sha, $0.colorIndex) },
                uniquingKeysWith: { first, _ in first }
            )
            branches = Self.ordered(branchList)
            unpushedSHAs = (try? await unpushedTask) ?? []
            errorMessage = nil
            hasMore = loaded.count == Self.pageSize

            captureSeenMarkerIfNeeded()
            recomputeNewCommits()
            await loadAttributions()
            recomputeFilteredRows()

            if let selected = selectedSHA, colorIndexBySHA[selected] != nil {
                // keep selection
            } else {
                selectedSHA = filteredRows.first?.commit.sha ?? rows.first?.commit.sha
            }
        } catch {
            errorMessage = error.localizedDescription
            commits = []
            rows = []
            filteredRows = []
            branches = []
            colorIndexBySHA = [:]
            hasMore = false
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading, !isSearching else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await gitService.log(
                at: repoPath, ref: selectedBranchFilter, skip: commits.count, maxCount: Self.pageSize
            )
            let known = Set(commits.map(\.sha))
            let newCommits = page.filter { !known.contains($0.sha) }
            commits.append(contentsOf: newCommits)
            hasMore = page.count == Self.pageSize
            rows = GitGraphLayout.rows(for: commits)
            colorIndexBySHA = Dictionary(
                rows.map { ($0.commit.sha, $0.colorIndex) },
                uniquingKeysWith: { first, _ in first }
            )
            recomputeNewCommits()
            recomputeFilteredRows()
        } catch {
            errorMessage = error.localizedDescription
            hasMore = false
        }
    }

    private func loadDetail() async {
        guard let selectedSHA else {
            detail = nil
            return
        }
        if let cached = detailCache[selectedSHA] {
            detail = cached
            return
        }
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        do {
            let loaded = try await gitService.commitDetail(sha: selectedSHA, at: repoPath)
            detailCache[selectedSHA] = loaded
            if self.selectedSHA == selectedSHA { detail = loaded }
        } catch {
            if self.selectedSHA == selectedSHA {
                detail = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadRefsAndRemote() async {
        if let worktrees = try? await gitService.listWorktrees(at: repoPath) {
            availableRefs = worktrees.map(\.branch).filter { $0 != "(detached)" }
            mainWorktreeBranch = worktrees.first(where: \.isMainWorktree)?.branch
        }
        remoteURL = try? await gitService.remoteURL(at: repoPath)
    }

    func loadAttributions() async {
        var map: [String: CommitAttribution] = [:]

        for commit in commits {
            guard let agent = AgentKind.inferredFromGitIdentity(
                name: commit.authorName, email: commit.authorEmail
            ) else { continue }
            map[commit.sha] = CommitAttribution(
                agent: agent, sessionID: nil, sessionTitle: nil,
                branchName: nil, source: .authorIdentity
            )
        }

        if let base = mainWorktreeBranch {
            for session in sessions {
                guard let branch = session.worktree?.branchName, branch != base else { continue }
                guard let shas = try? await gitService.commitsOnBranch(branch, notOn: base, at: repoPath) else { continue }
                let attribution = CommitAttribution(
                    agent: session.agent, sessionID: session.id, sessionTitle: session.title,
                    branchName: branch, source: .sessionBranch
                )
                for sha in shas { map[sha] = attribution }
            }
        }

        for commit in commits {
            guard let raw = commit.trailers["flotilla-agent"],
                  let agent = AgentKind.fromTrailerValue(raw) else { continue }
            let sessionID = commit.trailers["flotilla-session"].flatMap(UUID.init(uuidString:))
            let session = sessionID.flatMap { id in sessions.first { $0.id == id } }
            map[commit.sha] = CommitAttribution(
                agent: agent,
                sessionID: sessionID,
                sessionTitle: session?.title,
                branchName: session?.worktree?.branchName,
                source: .trailer
            )
        }

        attributions = map
    }

    private var lastSeenDefaultsKey: String { "flotilla.history.lastSeen.\(repoPath.path)" }

    private func captureSeenMarkerIfNeeded() {
        guard highlightUnseenCommits, !hasCapturedSeenMarker else { return }
        hasCapturedSeenMarker = true
        previouslySeenSHA = UserDefaults.standard.string(forKey: lastSeenDefaultsKey)
    }

    private func recomputeNewCommits() {
        guard highlightUnseenCommits, let previouslySeenSHA, !commits.isEmpty else {
            newCommitSHAs = []
            return
        }
        if let index = commits.firstIndex(where: { $0.sha == previouslySeenSHA }) {
            newCommitSHAs = Set(commits.prefix(index).map(\.sha))
        } else {
            newCommitSHAs = Set(commits.map(\.sha))
        }
    }

    func markAllAsSeen() {
        guard highlightUnseenCommits, let tip = commits.first?.sha else { return }
        UserDefaults.standard.set(tip, forKey: lastSeenDefaultsKey)
        previouslySeenSHA = tip
        newCommitSHAs = []
    }

    // MARK: Filtering

    private func recomputeFilteredRows() {
        var candidateCommits = commits
        if let filter = selectedBranchFilter, let tip = tipSHA(forBranch: filter) {
            let byS = Dictionary(commits.map { ($0.sha, $0) }, uniquingKeysWith: { first, _ in first })
            var reachable: Set<String> = []
            var frontier = [tip]
            while let sha = frontier.popLast() {
                guard reachable.insert(sha).inserted, let commit = byS[sha] else { continue }
                frontier.append(contentsOf: commit.parents)
            }
            candidateCommits = candidateCommits.filter { reachable.contains($0.sha) }
        }

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            candidateCommits = candidateCommits.filter { commit in
                commit.subject.lowercased().contains(query)
                    || commit.authorName.lowercased().contains(query)
                    || commit.authorEmail.lowercased().contains(query)
                    || commit.sha.lowercased().hasPrefix(query)
                    || commit.body.lowercased().contains(query)
            }
        }

        filteredRows = GitGraphLayout.rows(for: candidateCommits)

        if let currentSelected = selectedSHA, !filteredRows.contains(where: { $0.commit.sha == currentSelected }) {
            selectedSHA = filteredRows.first?.commit.sha
        }
    }

    private func tipSHA(forBranch name: String) -> String? {
        if let branch = branches.first(where: { $0.name == name }) { return branch.tipSHA }
        return commits.first { $0.refs.contains { $0.name == name } }?.sha
    }

    private static func ordered(_ branches: [GitBranch]) -> [GitBranch] {
        branches.sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            if lhs.isRemote != rhs.isRemote { return !lhs.isRemote }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
