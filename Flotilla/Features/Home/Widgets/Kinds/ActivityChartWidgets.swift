import SwiftUI
import Charts
import SessionKit
import GitKit
import DesignSystem

/// A big number with a small caption, for the headline figures inside cards.
/// Moved here from the old `HomeStatsSection` — shared by every chart widget.
struct HomeWidgetHeadlineFigure: View {
    let value: String
    let label: String
    var tint: Color = FlotillaColors.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(FlotillaTypography.caption2)
                .foregroundStyle(FlotillaColors.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Contributions

/// Weeks as columns, weekdays as rows, one accent hue from faint to full.
/// Weeks as columns, weekdays as rows, one accent hue from faint to full.
/// Cells are sized from both dimensions of the space the widget gives it —
/// never taller than seven rows fit, never wider than the weeks allow — so
/// the heatmap can't push its card out of its grid row.
struct ContributionHeatmap: View {
    var size: HomeWidgetSize = .wide
    let commitsByDay: [Date: Int]
    let currentStreak: Int
    let longestStreak: Int

    @State private var hoveredDay: Date?
    private let calendar = Calendar.current
    private let gap: CGFloat = 3
    private let maxCell: CGFloat = 22
    private let minCell: CGFloat = 8
    private let summaryHeight: CGFloat = 14
    private let monthHeight: CGFloat = 12

    private let statsWidth: CGFloat = 138

    private var today: Date { calendar.startOfDay(for: .now) }

    private func firstDay(weeks: Int) -> Date {
        let thisWeek = HomeActivity.startOfWeek(today, calendar)
        return calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) ?? thisWeek
    }

    /// Weeks shown and cell size for a content area of `size`.
    private func layout(for proxySize: CGSize) -> (weeks: Int, cell: CGFloat) {
        let maxWeeks = HomeActivity.heatmapWeeks
        if size == .wide {
            let separatorSpace: CGFloat = FlotillaSpacing.medium * 2 + 1
            let availableW = max(proxySize.width - statsWidth - separatorSpace, 1)
            let gridHeight = max(proxySize.height - monthHeight - 4, 1)
            let heightCell = (gridHeight - 6 * gap) / 7
            let widthCell = (availableW - CGFloat(maxWeeks - 1) * gap) / CGFloat(maxWeeks)
            let cell = min(maxCell, max(minCell, min(heightCell, widthCell)))
            let weeks = min(maxWeeks, max(1, Int((availableW + gap) / (cell + gap))))
            return (weeks, cell)
        } else {
            let gridHeight = max(proxySize.height - summaryHeight - monthHeight - 10, 1)
            let heightCell = (gridHeight - 6 * gap) / 7
            let widthCell = (proxySize.width - CGFloat(maxWeeks - 1) * gap) / CGFloat(maxWeeks)
            let cell = min(maxCell, max(minCell, min(heightCell, widthCell)))
            let weeks = min(maxWeeks, max(1, Int((proxySize.width + gap) / (cell + gap))))
            return (weeks, cell)
        }
    }

    private func total(weeks: Int) -> Int {
        let start = firstDay(weeks: weeks)
        return commitsByDay.filter { $0.key >= start }.values.reduce(0, +)
    }

    private var thresholds: [Int] {
        let busy = commitsByDay.values.filter { $0 > 0 }.sorted()
        guard !busy.isEmpty else { return [1, 2, 3] }
        return [0.25, 0.5, 0.75].map { busy[min(Int(Double(busy.count) * $0), busy.count - 1)] }
    }

    var body: some View {
        GeometryReader { proxy in
            let (weeks, cell) = layout(for: proxy.size)
            if size == .wide {
                HStack(alignment: .top, spacing: 0) {
                    sideSummary(weeks: weeks)
                        .frame(width: statsWidth, alignment: .leading)

                    Rectangle()
                        .fill(FlotillaColors.separator)
                        .frame(width: 1)
                        .padding(.vertical, 2)
                        .padding(.horizontal, FlotillaSpacing.medium)

                    grid(weeks: weeks, cell: cell)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    compactSummary(weeks: weeks)
                        .frame(width: max(CGFloat(weeks) * cell + CGFloat(weeks - 1) * gap, min(proxy.size.width, 320)), alignment: .leading)
                    grid(weeks: weeks, cell: cell)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
        }
    }

    private func sideSummary(weeks: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HomeWidgetHeadlineFigure(value: total(weeks: weeks).formatted(), label: "commits")
            HStack(spacing: FlotillaSpacing.medium) {
                HomeWidgetHeadlineFigure(
                    value: "\(currentStreak)d",
                    label: "streak",
                    tint: currentStreak > 0 ? FlotillaColors.accent : FlotillaColors.textPrimary
                )
                HomeWidgetHeadlineFigure(value: "\(longestStreak)d", label: "longest")
            }
            Spacer(minLength: 2)
            legend
                .font(FlotillaTypography.caption2)
                .foregroundStyle(FlotillaColors.textTertiary)
        }
    }

    private func compactSummary(weeks: Int) -> some View {
        HStack(spacing: FlotillaSpacing.medium) {
            (Text(total(weeks: weeks).formatted()).foregroundStyle(FlotillaColors.textPrimary).fontWeight(.semibold)
                + Text(" commits"))
            if currentStreak > 0 {
                (Text("\(currentStreak)d").foregroundStyle(FlotillaColors.accent).fontWeight(.semibold)
                    + Text(" streak"))
            }
            Spacer(minLength: 4)
            legend
        }
        .font(FlotillaTypography.caption2)
        .foregroundStyle(FlotillaColors.textTertiary)
        .lineLimit(1)
        .frame(height: summaryHeight)
    }

    private func grid(weeks: Int, cell: CGFloat) -> some View {
        let start = firstDay(weeks: weeks)
        let levels = thresholds
        return VStack(alignment: .leading, spacing: 4) {
            monthLabels(weeks: weeks, cell: cell, start: start)
            HStack(alignment: .top, spacing: gap) {
                ForEach(0..<weeks, id: \.self) { week in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { weekday in
                            let day = calendar.date(byAdding: .day, value: week * 7 + weekday, to: start)!
                            cellView(day: day, size: cell, thresholds: levels)
                        }
                    }
                }
            }
        }
    }

    private func monthLabels(weeks: Int, cell: CGFloat, start: Date) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<weeks, id: \.self) { week in
                let weekStart = calendar.date(byAdding: .weekOfYear, value: week, to: start)!
                let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: weekStart)!
                if week > 1, calendar.component(.month, from: weekStart) != calendar.component(.month, from: previous) {
                    Text(weekStart, format: .dateTime.month(.abbreviated))
                        .font(FlotillaTypography.caption3)
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .fixedSize()
                        .offset(x: CGFloat(week) * (cell + gap))
                }
            }
        }
        .frame(height: monthHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private func cellView(day: Date, size: CGFloat, thresholds: [Int]) -> some View {
        let count = commitsByDay[day, default: 0]
        if day > today {
            Color.clear.frame(width: size, height: size)
        } else {
            let isHovered = hoveredDay == day
            RoundedRectangle(cornerRadius: min(3, size / 4), style: .continuous)
                .fill(fill(for: count, thresholds: thresholds, isHovered: isHovered))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
                .onHover { hovering in
                    hoveredDay = hovering ? day : (hoveredDay == day ? nil : hoveredDay)
                }
                .help("\(count) commit\(count == 1 ? "" : "s") · \(day.formatted(.dateTime.weekday(.wide).month().day()))")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(count) commit\(count == 1 ? "" : "s"), \(day.formatted(.dateTime.weekday(.wide).month().day()))")
        }
    }

    private func fill(for count: Int, thresholds: [Int], isHovered: Bool) -> Color {
        guard count > 0 else {
            return FlotillaColors.textPrimary.opacity(isHovered ? 0.18 : 0.07)
        }
        let level = thresholds.filter { count > $0 }.count
        let opacities = [0.3, 0.5, 0.72, 1.0]
        let base = opacities[min(level, opacities.count - 1)]
        return FlotillaColors.accent.opacity(isHovered ? min(1.0, base + 0.15) : base)
    }

    private var legend: some View {
        HStack(spacing: 3) {
            Text("Less")
            ForEach([0.07, 0.3, 0.5, 0.72, 1.0], id: \.self) { opacity in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(opacity < 0.1 ? FlotillaColors.textPrimary.opacity(opacity) : FlotillaColors.accent.opacity(opacity))
                    .frame(width: 9, height: 9)
            }
            Text("More")
        }
        .accessibilityHidden(true)
    }
}

/// Reads the widget's activity slice and hands the heatmap its data.
struct ContributionsWidgetContent: View {
    var size: HomeWidgetSize = .wide
    let activity: HomeActivity?

    var body: some View {
        if let activity {
            ContributionHeatmap(
                size: size,
                commitsByDay: activity.commitsByDay,
                currentStreak: activity.currentStreak(),
                longestStreak: activity.longestStreak()
            )
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Weekly Rhythm

/// Additions above the baseline, deletions mirrored below — one axis, one
/// unit, so the two never need separate scales.
struct RhythmChartContent: View {
    let linesByDay: [Date: GitDiffStat]
    var windowDays: Int = HomeActivity.rhythmDays

    @State private var selectedDay: Date?
    private let calendar = Calendar.current

    private var days: [Date] {
        let today = calendar.startOfDay(for: .now)
        return (0..<windowDays).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
    }

    private var totals: GitDiffStat {
        days.reduce(GitDiffStat.zero) { $0 + linesByDay[$1, default: .zero] }
    }

    private var chartDomain: ClosedRange<Date> {
        let start = days.first ?? calendar.startOfDay(for: .now)
        let lastDay = days.last ?? start
        let end = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
        return start...end
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            HStack(spacing: FlotillaSpacing.xLarge) {
                HomeWidgetHeadlineFigure(value: "+\(totals.additions.formatted(.number.notation(.compactName)))", label: "added", tint: FlotillaColors.diffAdded)
                HomeWidgetHeadlineFigure(value: "−\(totals.deletions.formatted(.number.notation(.compactName)))", label: "removed", tint: FlotillaColors.diffRemoved)
                Spacer(minLength: 0)
            }

            GeometryReader { proxy in
                let slotWidth = max((proxy.size.width - 40) / CGFloat(days.count), 1)
                let barWidth = min(max(slotWidth * 0.55, 3), 16)
                let cornerRadius = min(3, barWidth / 2)

                Chart {
                    ForEach(days, id: \.self) { day in
                        let stat = linesByDay[day, default: .zero]
                        if stat.additions > 0 {
                            BarMark(
                                x: .value("Day", day, unit: .day),
                                y: .value("Lines", stat.additions),
                                width: .fixed(barWidth)
                            )
                            .foregroundStyle(FlotillaColors.diffAdded.gradient)
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: cornerRadius, topTrailingRadius: cornerRadius))
                        }
                        if stat.deletions > 0 {
                            BarMark(
                                x: .value("Day", day, unit: .day),
                                y: .value("Lines", -stat.deletions),
                                width: .fixed(barWidth)
                            )
                            .foregroundStyle(FlotillaColors.diffRemoved.gradient)
                            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius))
                        }
                    }
                    RuleMark(y: .value("Baseline", 0))
                        .foregroundStyle(FlotillaColors.separatorStrong)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    if let selectedDay {
                        let stat = linesByDay[selectedDay, default: .zero]
                        RuleMark(x: .value("Day", selectedDay, unit: .day))
                            .foregroundStyle(FlotillaColors.textPrimary.opacity(0.15))
                            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                tooltip(day: selectedDay, stat: stat)
                            }
                    }
                }
                .chartXSelection(value: Binding(
                    get: { selectedDay },
                    set: { selectedDay = $0.map { calendar.startOfDay(for: $0) } }
                ))
                .chartXScale(domain: chartDomain)
                .chartXAxis {
                    AxisMarks(values: strideValues) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(FlotillaColors.textPrimary.opacity(0.05))
                        AxisValueLabel {
                            if let lines = value.as(Int.self) {
                                Text(abs(lines), format: .number.notation(.compactName))
                                    .foregroundStyle(FlotillaColors.textTertiary)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var strideValues: AxisMarkValues {
        if windowDays <= 14 {
            return .stride(by: .day, count: 2)
        } else if windowDays <= 28 {
            return .stride(by: .weekOfYear, count: 1)
        } else {
            return .stride(by: .weekOfYear, count: 2)
        }
    }

    private func tooltip(day: Date, stat: GitDiffStat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(day, format: .dateTime.weekday(.abbreviated).month().day())
                .font(FlotillaTypography.caption2.weight(.semibold))
                .foregroundStyle(FlotillaColors.textPrimary)
            Text("+\(stat.additions)  −\(stat.deletions)")
                .font(FlotillaTypography.caption2.monospacedDigit())
                .foregroundStyle(FlotillaColors.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(FlotillaColors.surfaceElevated, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Codebase Growth

/// Cumulative net lines over the widget's window. "All projects" draws the
/// combined total with each project as a faint line behind it; picking a
/// project inline shows that one alone, on its own scale — a transient
/// view, not saved: it resets to "All projects" whenever Home is left.
struct GrowthChartContent: View {
    let netLinesByWeek: [UUID: [Date: Int]]
    let projects: [Project]
    var windowWeeks: Int = HomeActivity.growthWeeks

    @State private var selectedProjectID: UUID?
    @State private var hoveredWeek: Date?

    private struct Point: Identifiable {
        let series: String
        let week: Date
        let total: Int
        var id: String { "\(series)-\(week.timeIntervalSinceReferenceDate)" }
    }

    private var weeks: [Date] {
        let thisWeek = HomeActivity.startOfWeek(.now)
        return (0..<windowWeeks).reversed().compactMap {
            Calendar.current.date(byAdding: .weekOfYear, value: -$0, to: thisWeek)
        }
    }

    private var activeProjects: [Project] {
        projects
            .filter { netLinesByWeek[$0.id] != nil }
            .sorted { churn($0) > churn($1) }
    }

    private func churn(_ project: Project) -> Int {
        netLinesByWeek[project.id]?.values.map(abs).reduce(0, +) ?? 0
    }

    private func cumulative(_ weekly: [Date: Int], series: String) -> [Point] {
        var running = 0
        return weeks.map { week in
            running += weekly[week, default: 0]
            return Point(series: series, week: week, total: running)
        }
    }

    private var selectedProject: Project? {
        selectedProjectID.flatMap { id in projects.first { $0.id == id } }
    }

    private var focus: (points: [Point], tint: Color) {
        if let project = selectedProject {
            return (cumulative(netLinesByWeek[project.id] ?? [:], series: project.name), ProjectMark.tint(for: project))
        }
        let combined = netLinesByWeek.values.reduce(into: [Date: Int]()) { $0.merge($1, uniquingKeysWith: +) }
        return (cumulative(combined, series: "All projects"), FlotillaColors.accent)
    }

    private var background: [Point] {
        guard selectedProject == nil else { return [] }
        return activeProjects.flatMap { cumulative(netLinesByWeek[$0.id] ?? [:], series: $0.name) }
    }

    var body: some View {
        if activeProjects.isEmpty {
            HomeWidgetAllClearState(message: "No commits in this window.")
        } else {
            let focus = focus
            VStack(alignment: .leading, spacing: 6) {
                if selectedProjectID == nil {
                    scopePicker
                }
                headline(focus.points)
                chart(focus: focus.points, tint: focus.tint)
            }
            .onDisappear { selectedProjectID = nil }
        }
    }

    private var scopePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                scopeChip(id: nil, title: "All projects", mark: nil)
                ForEach(activeProjects) { project in
                    scopeChip(id: project.id, title: project.name, mark: project)
                }
            }
        }
    }

    private func scopeChip(id: UUID?, title: String, mark: Project?) -> some View {
        let isSelected = selectedProjectID == id
        return Button {
            withAnimation(.snappy) { selectedProjectID = id }
        } label: {
            HStack(spacing: 6) {
                if let mark {
                    ProjectMark(title: mark.name, tint: ProjectMark.tint(for: mark), size: 16)
                }
                Text(title).font(FlotillaTypography.caption.weight(.medium))
            }
            .foregroundStyle(isSelected ? FlotillaColors.textPrimary : FlotillaColors.textSecondary)
            .padding(.horizontal, FlotillaSpacing.small + 2)
            .frame(height: 24)
            .background(FlotillaColors.textPrimary.opacity(isSelected ? 0.14 : 0.05), in: Capsule())
            .overlay { Capsule().strokeBorder(FlotillaColors.textPrimary.opacity(isSelected ? 0.18 : 0), lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func headline(_ points: [Point]) -> some View {
        let shown = hoveredWeek.flatMap { week in points.last { $0.week <= week } } ?? points.last
        return HStack(alignment: .firstTextBaseline, spacing: FlotillaSpacing.small) {
            Text(shown?.total ?? 0, format: .number.notation(.compactName).sign(strategy: .always(includingZero: false)))
                .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(FlotillaColors.textPrimary)
                .contentTransition(.numericText())
            Text(hoveredWeek == nil
                 ? "net lines in the window"
                 : "net lines by \(shown?.week.formatted(.dateTime.month(.abbreviated).day()) ?? "")")
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textTertiary)
            if let project = selectedProject {
                Spacer()
                Button {
                    withAnimation(.snappy) { selectedProjectID = nil }
                } label: {
                    HStack(spacing: 5) {
                        ProjectMark(title: project.name, tint: ProjectMark.tint(for: project), size: 14)
                        Text(project.name)
                            .font(FlotillaTypography.caption.weight(.medium))
                            .foregroundStyle(FlotillaColors.textPrimary)
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(FlotillaColors.textPrimary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Show all projects")
                .accessibilityLabel("Clear filter, show all projects")
            }
        }
    }

    private func chart(focus: [Point], tint: Color) -> some View {
        Chart {
            ForEach(background) { point in
                LineMark(x: .value("Week", point.week, unit: .weekOfYear), y: .value("Net lines", point.total), series: .value("Project", point.series))
                    .foregroundStyle(FlotillaColors.textPrimary.opacity(0.18))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
            ForEach(focus) { point in
                AreaMark(x: .value("Week", point.week, unit: .weekOfYear), y: .value("Net lines", point.total), series: .value("Project", "focus"))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.3), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Week", point.week, unit: .weekOfYear), y: .value("Net lines", point.total), series: .value("Project", "focus"))
                    .foregroundStyle(tint)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            RuleMark(y: .value("Zero", 0)).foregroundStyle(FlotillaColors.separatorStrong)
            if let hoveredWeek, let point = focus.last(where: { $0.week <= hoveredWeek }) {
                RuleMark(x: .value("Week", point.week, unit: .weekOfYear))
                    .foregroundStyle(FlotillaColors.textPrimary.opacity(0.15))
                PointMark(x: .value("Week", point.week, unit: .weekOfYear), y: .value("Net lines", point.total))
                    .foregroundStyle(tint)
                    .symbolSize(60)
            }
        }
        .chartXSelection(value: $hoveredWeek)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(FlotillaColors.textPrimary.opacity(0.05))
                AxisValueLabel {
                    if let lines = value.as(Int.self) {
                        Text(lines, format: .number.notation(.compactName))
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .animation(.snappy, value: selectedProjectID)
    }
}
