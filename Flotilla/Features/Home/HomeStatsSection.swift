import SwiftUI
import Charts
import SessionKit
import GitKit
import DesignSystem

/// The foot of Home: your work over time, across every project. This is the
/// one thing no other screen shows — the sidebar is *now*, a project
/// workspace is *one repository*.
struct HomeStatsSection: View {
    /// `nil` while history is still being read.
    let activity: HomeActivity?
    let projects: [Project]

    @State private var width: CGFloat = 1_000
    private var isWide: Bool { width >= 820 }

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
            HomeSectionTitle("Your activity")

            if let activity {
                HomeStatCard(title: "Contributions", subtitle: "Commits per day, last twelve months") {
                    ContributionHeatmap(commitsByDay: activity.commitsByDay)
                }
                pair {
                    HomeStatCard(title: "Weekly rhythm", subtitle: "Lines added and removed, last four weeks") {
                        RhythmChart(linesByDay: activity.linesByDay)
                    }
                } trailing: {
                    HomeStatCard(title: "Agent share", subtitle: "Which agents wrote your commits, last 30 days") {
                        AgentShareView(contributions: activity.contributions)
                    }
                }
                HomeStatCard(title: "Codebase growth", subtitle: "Net lines added, last twelve weeks") {
                    GrowthChart(netLinesByWeek: activity.netLinesByWeek, projects: projects)
                }
            } else {
                HomeStatCard(title: "Contributions", subtitle: "Reading history…") {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityIdentifier(AXID.homeStats.rawValue)
    }

    @ViewBuilder
    private func pair<Leading: View, Trailing: View>(
        @ViewBuilder _ leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        if isWide {
            HStack(alignment: .top, spacing: FlotillaSpacing.medium) {
                leading().frame(maxWidth: .infinity)
                trailing().frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            leading()
            trailing()
        }
    }
}

// MARK: - Card

struct HomeStatCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.large) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(FlotillaColors.textPrimary)
                Text(subtitle)
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
            content
        }
        .padding(FlotillaSpacing.large + 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: FlotillaRadius.modal, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.modal, style: .continuous)
                .strokeBorder(FlotillaColors.textPrimary.opacity(0.08), lineWidth: FlotillaBorderWidth.thin)
        }
    }
}

/// A big number with a small caption, for the headline figures inside cards.
private struct HeadlineFigure: View {
    let value: String
    let label: String
    var tint: Color = FlotillaColors.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(FlotillaTypography.caption2)
                .foregroundStyle(FlotillaColors.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Contribution Heatmap

/// Weeks as columns, weekdays as rows, one accent hue from faint to full.
/// Levels are quartiles of your own busy days, so a quiet month still reads.
/// Cells keep a comfortable fixed size and the grid shows as many recent
/// weeks as fit, up to a year.
private struct ContributionHeatmap: View {
    let commitsByDay: [Date: Int]

    @State private var width: CGFloat = 0
    private let calendar = Calendar.current
    private let gap: CGFloat = 3
    private let maxCell: CGFloat = 22
    private let minCell: CGFloat = 9

    private var today: Date { calendar.startOfDay(for: .now) }

    private var layout: (weeks: Int, cell: CGFloat) {
        let maxWeeks = HomeActivity.heatmapWeeks
        guard width > 0 else { return (maxWeeks, minCell) }
        let fitted = (width - CGFloat(maxWeeks - 1) * gap) / CGFloat(maxWeeks)
        if fitted >= minCell { return (maxWeeks, min(fitted, maxCell)) }
        return (max(Int((width + gap) / (minCell + gap)), 1), minCell)
    }

    private func firstDay(weeks: Int) -> Date {
        let thisWeek = HomeActivity.startOfWeek(today, calendar)
        return calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) ?? thisWeek
    }

    private var windowStart: Date { firstDay(weeks: HomeActivity.heatmapWeeks) }

    private var total: Int {
        commitsByDay.filter { $0.key >= windowStart }.values.reduce(0, +)
    }

    /// Consecutive days with commits, ending today — or yesterday, so a
    /// streak isn't "broken" before you've had a chance to commit today.
    private var currentStreak: Int {
        var day = commitsByDay[today, default: 0] > 0 ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        var streak = 0
        while commitsByDay[day, default: 0] > 0 {
            streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }

    private var longestStreak: Int {
        var longest = 0, run = 0
        var day = windowStart
        while day <= today {
            run = commitsByDay[day, default: 0] > 0 ? run + 1 : 0
            longest = max(longest, run)
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return longest
    }

    private var thresholds: [Int] {
        let busy = commitsByDay.values.filter { $0 > 0 }.sorted()
        guard !busy.isEmpty else { return [1, 2, 3] }
        return [0.25, 0.5, 0.75].map { busy[min(Int(Double(busy.count) * $0), busy.count - 1)] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
            HStack(alignment: .bottom, spacing: FlotillaSpacing.xLarge) {
                HeadlineFigure(value: total.formatted(), label: "commits")
                HeadlineFigure(
                    value: "\(currentStreak)d",
                    label: "current streak",
                    tint: currentStreak > 0 ? FlotillaColors.accent : FlotillaColors.textPrimary
                )
                HeadlineFigure(value: "\(longestStreak)d", label: "longest streak")
                Spacer(minLength: 0)
                legend
            }
            // A GeometryReader always takes the offered width, so the grid
            // can never widen the card it's measuring; the height follows
            // from the cell size that width allows.
            GeometryReader { proxy in
                grid
                    .onAppear { width = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newWidth in width = newWidth }
            }
            .frame(height: 18 + 7 * layout.cell + 6 * gap)
        }
    }

    private var grid: some View {
        let (weeks, cell) = layout
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
                // Skip a label squeezed against the grid's first column.
                if week > 1, calendar.component(.month, from: weekStart) != calendar.component(.month, from: previous) {
                    Text(weekStart, format: .dateTime.month(.abbreviated))
                        .font(FlotillaTypography.caption2)
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .fixedSize()
                        .offset(x: CGFloat(week) * (cell + gap))
                }
            }
        }
        .frame(height: 14, alignment: .topLeading)
    }

    @ViewBuilder
    private func cellView(day: Date, size: CGFloat, thresholds: [Int]) -> some View {
        let count = commitsByDay[day, default: 0]
        let isFuture = day > today
        RoundedRectangle(cornerRadius: min(3, size / 4), style: .continuous)
            .fill(isFuture ? Color.clear : fill(for: count, thresholds: thresholds))
            .frame(width: size, height: size)
            .help(isFuture ? "" : "\(count) commit\(count == 1 ? "" : "s") · \(day.formatted(.dateTime.weekday(.wide).month().day()))")
    }

    private func fill(for count: Int, thresholds: [Int]) -> Color {
        guard count > 0 else { return FlotillaColors.textPrimary.opacity(0.07) }
        let level = thresholds.filter { count > $0 }.count
        return FlotillaColors.accent.opacity([0.3, 0.5, 0.72, 1.0][level])
    }

    private var legend: some View {
        HStack(spacing: 3) {
            Text("Less")
            ForEach([0.07, 0.3, 0.5, 0.72, 1.0], id: \.self) { opacity in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(opacity < 0.1 ? FlotillaColors.textPrimary.opacity(opacity) : FlotillaColors.accent.opacity(opacity))
                    .frame(width: 10, height: 10)
            }
            Text("More")
        }
        .font(FlotillaTypography.caption2)
        .foregroundStyle(FlotillaColors.textTertiary)
        .accessibilityHidden(true)
    }
}

// MARK: - Weekly Rhythm

/// Additions above the baseline, deletions mirrored below — one axis, one
/// unit, so the two never need separate scales.
private struct RhythmChart: View {
    let linesByDay: [Date: GitDiffStat]

    @State private var selectedDay: Date?
    private let calendar = Calendar.current

    private var days: [Date] {
        let today = calendar.startOfDay(for: .now)
        return (0..<HomeActivity.rhythmDays).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
    }

    private var totals: GitDiffStat {
        linesByDay.values.reduce(.zero, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
            HStack(spacing: FlotillaSpacing.xLarge) {
                HeadlineFigure(value: "+\(totals.additions.formatted(.number.notation(.compactName)))", label: "added", tint: FlotillaColors.diffAdded)
                HeadlineFigure(value: "−\(totals.deletions.formatted(.number.notation(.compactName)))", label: "removed", tint: FlotillaColors.diffRemoved)
                Spacer(minLength: 0)
            }

            Chart {
                ForEach(days, id: \.self) { day in
                    let stat = linesByDay[day, default: .zero]
                    BarMark(x: .value("Day", day, unit: .day), y: .value("Lines", stat.additions))
                        .foregroundStyle(FlotillaColors.diffAdded.gradient)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3))
                    BarMark(x: .value("Day", day, unit: .day), y: .value("Lines", -stat.deletions))
                        .foregroundStyle(FlotillaColors.diffRemoved.gradient)
                        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3))
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
            // The selection is wherever the pointer sits inside a day; the data
            // is keyed by that day's start, so snap before looking it up.
            .chartXSelection(value: Binding(
                get: { selectedDay },
                set: { selectedDay = $0.map { calendar.startOfDay(for: $0) } }
            ))
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: false)
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
            .frame(height: 170)
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

/// Cumulative net lines over twelve weeks. "All projects" draws the combined
/// total with each project as a faint line behind it; picking a project
/// shows that one alone, on its own scale.
private struct GrowthChart: View {
    let netLinesByWeek: [UUID: [Date: Int]]
    let projects: [Project]

    /// `nil` is "All projects".
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
        return (0..<HomeActivity.growthWeeks).reversed().compactMap {
            Calendar.current.date(byAdding: .weekOfYear, value: -$0, to: thisWeek)
        }
    }

    /// Projects that committed in the window, busiest first.
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
            Text("No commits in the last twelve weeks.")
                .font(FlotillaTypography.callout)
                .foregroundStyle(FlotillaColors.textTertiary)
        } else {
            let focus = focus
            VStack(alignment: .leading, spacing: FlotillaSpacing.large) {
                scopePicker
                headline(focus.points)
                chart(focus: focus.points, tint: focus.tint)
            }
        }
    }

    // MARK: Picker

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
                Text(title)
                    .font(FlotillaTypography.caption.weight(.medium))
            }
            .foregroundStyle(isSelected ? FlotillaColors.textPrimary : FlotillaColors.textSecondary)
            .padding(.horizontal, FlotillaSpacing.small + 2)
            .frame(height: 26)
            .background(
                FlotillaColors.textPrimary.opacity(isSelected ? 0.14 : 0.05),
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(FlotillaColors.textPrimary.opacity(isSelected ? 0.18 : 0), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Headline

    private func headline(_ points: [Point]) -> some View {
        let shown = hoveredWeek.flatMap { week in points.last { $0.week <= week } } ?? points.last
        return HStack(alignment: .firstTextBaseline, spacing: FlotillaSpacing.small) {
            Text(shown?.total ?? 0, format: .number.notation(.compactName).sign(strategy: .always(includingZero: false)))
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(FlotillaColors.textPrimary)
                .contentTransition(.numericText())
            Text(hoveredWeek == nil
                 ? "net lines in twelve weeks"
                 : "net lines by \(shown?.week.formatted(.dateTime.month(.abbreviated).day()) ?? "")")
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textTertiary)
        }
    }

    // MARK: Chart

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
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(FlotillaColors.separatorStrong)
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
            AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(FlotillaColors.textPrimary.opacity(0.05))
                AxisValueLabel {
                    if let lines = value.as(Int.self) {
                        Text(lines, format: .number.notation(.compactName))
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }
                }
            }
        }
        .frame(height: 200)
        .animation(.snappy, value: selectedProjectID)
    }
}
