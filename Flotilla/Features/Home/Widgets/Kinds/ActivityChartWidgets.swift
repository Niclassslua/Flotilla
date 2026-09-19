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
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
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
/// Shows as many recent weeks as its width allows — the same behavior at
/// every size, medium just gets less width than wide.
struct ContributionHeatmap: View {
    let commitsByDay: [Date: Int]
    let currentStreak: Int
    let longestStreak: Int

    @State private var width: CGFloat = 0
    @State private var hoveredDay: Date?
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

    private var thresholds: [Int] {
        let busy = commitsByDay.values.filter { $0 > 0 }.sorted()
        guard !busy.isEmpty else { return [1, 2, 3] }
        return [0.25, 0.5, 0.75].map { busy[min(Int(Double(busy.count) * $0), busy.count - 1)] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
            HStack(alignment: .bottom, spacing: FlotillaSpacing.xLarge) {
                HomeWidgetHeadlineFigure(value: total.formatted(), label: "commits")
                HomeWidgetHeadlineFigure(
                    value: "\(currentStreak)d",
                    label: "current streak",
                    tint: currentStreak > 0 ? FlotillaColors.accent : FlotillaColors.textPrimary
                )
                HomeWidgetHeadlineFigure(value: "\(longestStreak)d", label: "longest streak")
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
        if isFuture {
            Color.clear.frame(width: size, height: size)
        } else {
            let isHovered = hoveredDay == day
            let cornerRadius = min(3, size / 4)
            let scale: CGFloat = isHovered ? max(1.3, 18.0 / size) : 1.0

            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill(for: count, thresholds: thresholds, isHovered: isHovered))
                if isHovered {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            count == 0 ? FlotillaColors.textPrimary.opacity(0.28) : Color.white.opacity(0.45),
                            lineWidth: 1
                        )
                    Text(count >= 1000 ? "\(count / 1000)k" : "\(count)")
                        .font(.system(size: max(8, size * 0.58), weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(count == 0 ? FlotillaColors.textPrimary : FlotillaColors.accentContent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 1)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .onHover { hovering in
                hoveredDay = hovering ? day : (hoveredDay == day ? nil : hoveredDay)
            }
            .scaleEffect(scale)
            .zIndex(isHovered ? 10 : 0)
            .shadow(color: .black.opacity(isHovered ? 0.35 : 0), radius: 2, y: 1)
            .animation(.snappy(duration: 0.15), value: isHovered)
            .help("\(count) commit\(count == 1 ? "" : "s") · \(day.formatted(.dateTime.weekday(.wide).month().day()))")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(count) commit\(count == 1 ? "" : "s"), \(day.formatted(.dateTime.weekday(.wide).month().day()))")
        }
    }

    private func fill(for count: Int, thresholds: [Int], isHovered: Bool = false) -> Color {
        guard count > 0 else {
            return FlotillaColors.textPrimary.opacity(isHovered ? 0.18 : 0.07)
        }
        let level = thresholds.filter { count > $0 }.count
        let opacities = [0.3, 0.5, 0.72, 1.0]
        let baseOpacity = opacities[min(level, opacities.count - 1)]
        return FlotillaColors.accent.opacity(isHovered ? min(1.0, baseOpacity + 0.15) : baseOpacity)
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

/// The grid widget entry point: reads its activity slice, computes the
/// streaks and hands the pure heatmap its data.
struct ContributionsWidgetContent: View {
    let activity: HomeActivity?

    var body: some View {
        if let activity {
            ContributionHeatmap(
                commitsByDay: activity.commitsByDay,
                currentStreak: activity.currentStreak(),
                longestStreak: activity.longestStreak()
            )
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
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

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
            HStack(spacing: FlotillaSpacing.xLarge) {
                HomeWidgetHeadlineFigure(value: "+\(totals.additions.formatted(.number.notation(.compactName)))", label: "added", tint: FlotillaColors.diffAdded)
                HomeWidgetHeadlineFigure(value: "−\(totals.deletions.formatted(.number.notation(.compactName)))", label: "removed", tint: FlotillaColors.diffRemoved)
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
            .frame(minHeight: 120)
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
            VStack(alignment: .leading, spacing: FlotillaSpacing.small + 2) {
                scopePicker
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
                .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(FlotillaColors.textPrimary)
                .contentTransition(.numericText())
            Text(hoveredWeek == nil
                 ? "net lines in the window"
                 : "net lines by \(shown?.week.formatted(.dateTime.month(.abbreviated).day()) ?? "")")
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textTertiary)
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
            AxisMarks(values: .stride(by: .weekOfYear, count: max(1, windowWeeks / 6))) { _ in
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
        .frame(minHeight: 130)
        .animation(.snappy, value: selectedProjectID)
    }
}
