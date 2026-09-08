import SwiftUI
import SessionKit
import GitKit
import DesignSystem

enum GraphMetrics {
    static let rowHeight: CGFloat = 34
    static let laneWidth: CGFloat = 15
    static let gutterLeading: CGFloat = 10
    static let gutterTrailing: CGFloat = 6
    static let maxVisibleLanes = 9

    static let contentInset: CGFloat = 10
    static let columnSpacing: CGFloat = 8
    static let refTextMaxWidth: CGFloat = 112
    static let statColumn: CGFloat = 88
    static let authorColumn: CGFloat = 52
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

struct GraphCommitRow: View {
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
            ForEach(commit.refs.prefix(1), id: \.name) { ref in
                CommitRefChip(ref: ref, maxTextWidth: GraphMetrics.refTextMaxWidth)
                    .help(ref.name)
            }
            if commit.refs.count > 1 {
                CommitRefChip(
                    text: "+\(commit.refs.count - 1)",
                    systemImage: "ellipsis",
                    tint: FlotillaColors.textTertiary
                )
                .help(commit.refs.dropFirst().map(\.name).joined(separator: "\n"))
            }

            Spacer(minLength: FlotillaSpacing.small)

            GraphStatCell(stat: commit.stat, fileCount: commit.changedFileCount)
                .frame(minWidth: GraphMetrics.statColumn, alignment: .trailing)

            authorIdentity
                .frame(width: GraphMetrics.authorColumn, alignment: .leading)

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
        HStack(spacing: 3.5) {
            ProjectMark(
                title: commit.authorName,
                tint: ProjectMark.tint(forKey: commit.authorEmail),
                size: 18
            )
            .help(commit.authorEmail.isEmpty ? commit.authorName : "\(commit.authorName) <\(commit.authorEmail)>")

            if let attribution {
                Image(systemName: "plus")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(FlotillaColors.textTertiary.opacity(0.6))

                ProviderLogo(agent: attribution.agent)
                    .frame(width: 16, height: 16)
                    .help("\(attribution.agent.displayName)\(attribution.sessionTitle.map { " · \($0)" } ?? "") — \(attribution.source.explanation)")
            }
        }
    }

    private var accessibilityDescription: String {
        var parts = [commit.subject]
        if let attribution {
            parts.append("authored by \(commit.authorName), assisted by \(attribution.agent.displayName) (\(attribution.source.explanation))")
        } else {
            parts.append("authored by \(commit.authorName)")
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

struct GraphLanePainter: View {
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

struct GraphStatCell: View {
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

struct GraphBranchChip: View {
    let title: String
    let systemImage: String
    var isBranch: Bool = false
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
                } else if isBranch {
                    GitBranchIcon(size: 8)
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

struct GraphLegendItem: View {
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

