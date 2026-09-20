import SwiftUI
import GitKit
import DesignSystem

// MARK: - Streak

struct StreakWidgetContent: View {
    let activity: HomeActivity?

    var body: some View {
        if let activity {
            let current = activity.currentStreak()
            let best = activity.longestStreak()
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                Text("\(current)")
                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(current > 0 ? FlotillaColors.textPrimary : FlotillaColors.textTertiary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline) {
                    Text("day streak")
                        .foregroundStyle(FlotillaColors.textSecondary)
                    Spacer(minLength: 4)
                    Text("best \(best)d")
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
                .font(FlotillaTypography.caption)
                Spacer(minLength: 6)
                week(activity: activity)
            }
        } else {
            HomeWidgetSkeleton(kind: .streak, size: .small)
        }
    }

    private func week(activity: HomeActivity) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let weekStart = HomeActivity.startOfWeek(today, calendar)
        let labels = ["M", "T", "W", "T", "F", "S", "S"]
        return HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { offset in
                let day = calendar.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
                VStack(spacing: 3) {
                    Circle().fill(fill(day: day, today: today, activity: activity)).frame(width: 11, height: 11)
                    Text(labels[offset]).font(.system(size: 8, weight: .medium)).foregroundStyle(FlotillaColors.textTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func fill(day: Date, today: Date, activity: HomeActivity) -> Color {
        if day > today { return FlotillaColors.textPrimary.opacity(0.03) }
        return activity.commitsByDay[day, default: 0] > 0 ? FlotillaColors.accent : FlotillaColors.textPrimary.opacity(0.1)
    }
}

// MARK: - Today

struct TodayWidgetContent: View {
    let size: HomeWidgetSize
    let activity: HomeActivity?
    let sessionsStartedToday: Int

    var body: some View {
        guard let activity else {
            return AnyView(HomeWidgetSkeleton(kind: .today, size: size))
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let commits = activity.commitsByDay[today, default: 0]
        let stat = activity.linesByDay[today, default: .zero]
        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(commits)")
                        .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(FlotillaColors.textPrimary)
                    Text(commits == 1 ? "commit" : "commits")
                        .font(FlotillaTypography.caption)
                        .foregroundStyle(FlotillaColors.textSecondary)
                }
                HStack(spacing: 4) {
                    Text("+\(stat.additions.formatted())").foregroundStyle(FlotillaColors.diffAdded)
                    Text("−\(stat.deletions.formatted())").foregroundStyle(FlotillaColors.diffRemoved)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                HStack(spacing: 3) {
                    Image(systemName: "terminal.fill").font(.system(size: 9))
                    Text("\(sessionsStartedToday) session\(sessionsStartedToday == 1 ? "" : "s") started")
                }
                .font(FlotillaTypography.caption2)
                .foregroundStyle(FlotillaColors.textTertiary)
                if size == .medium {
                    Spacer(minLength: 0)
                    hourlySparkline(activity: activity, today: today, calendar: calendar)
                }
            }
        )
    }

    private func hourlySparkline(activity: HomeActivity, today: Date, calendar: Calendar) -> some View {
        var hourly = Array(repeating: 0, count: 24)
        for timestamp in activity.commitTimestamps where calendar.isDate(timestamp, inSameDayAs: today) {
            hourly[calendar.component(.hour, from: timestamp)] += 1
        }
        let peak = max(hourly.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<24, id: \.self) { hour in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(hourly[hour] == 0 ? FlotillaColors.textPrimary.opacity(0.08) : FlotillaColors.accent)
                    .frame(width: 4, height: max(2, 22 * CGFloat(hourly[hour]) / CGFloat(peak)))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 22, alignment: .bottom)
    }
}

// MARK: - Busiest Hours

struct BusiestHoursWidgetContent: View {
    let size: HomeWidgetSize
    /// `[weekday (Mon-first)][hour]`.
    let grid: [[Int]]

    private var peak: Int { grid.flatMap { $0 }.max() ?? 1 }
    private var total: Int { grid.flatMap { $0 }.reduce(0, +) }

    private var busiest: (day: Int, hour: Int) {
        var best = (0, 0, -1)
        for (day, hours) in grid.enumerated() {
            for (hour, count) in hours.enumerated() where count > best.2 { best = (day, hour, count) }
        }
        return (best.0, best.1)
    }

    private var eveningShare: Int {
        guard total > 0 else { return 0 }
        let evening = grid.map { $0[20...].reduce(0, +) }.reduce(0, +)
        return Int((Double(evening) / Double(total) * 100).rounded())
    }

    private let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private let labelWidth: CGFloat = 12
    private let axisHeight: CGFloat = 10

    var body: some View {
        if total == 0 {
            HomeWidgetAllClearState(message: "No commits in this window.")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(eveningShare)% after 8 pm")
                        .foregroundStyle(FlotillaColors.textTertiary)
                    Spacer()
                    Text("Peak \(days[busiest.day]) \(busiest.hour):00")
                        .fontWeight(.semibold)
                        .foregroundStyle(FlotillaColors.accent)
                }
                .font(FlotillaTypography.caption2)
                GeometryReader { proxy in
                    // One pitch for both axes, the smaller of what 24 columns
                    // and 7 rows allow, so the dots stay round and fit.
                    let pitch = min(
                        (proxy.size.width - labelWidth) / 24,
                        (proxy.size.height - axisHeight) / 7
                    )
                    let gridWidth = labelWidth + pitch * 24
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<7, id: \.self) { day in
                            HStack(spacing: 0) {
                                Text(days[day].prefix(1))
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(FlotillaColors.textTertiary)
                                    .frame(width: labelWidth, alignment: .leading)
                                ForEach(0..<24, id: \.self) { hour in
                                    dot(grid[day][hour]).frame(width: pitch, height: pitch)
                                }
                            }
                        }
                        HStack(spacing: 0) {
                            Color.clear.frame(width: labelWidth, height: axisHeight)
                            ForEach(0..<24, id: \.self) { hour in
                                Text(hour % 6 == 0 ? "\(hour)" : "")
                                    .font(.system(size: 7, weight: .medium))
                                    .foregroundStyle(FlotillaColors.textTertiary)
                                    .fixedSize()
                                    .frame(width: pitch, height: axisHeight, alignment: .leading)
                            }
                        }
                    }
                    .frame(width: gridWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private func dot(_ count: Int) -> some View {
        let level = Double(count) / Double(max(peak, 1))
        return Circle()
            .fill(count == 0 ? FlotillaColors.textPrimary.opacity(0.06) : FlotillaColors.accent.opacity(0.25 + 0.75 * level))
            .scaleEffect(count == 0 ? 0.4 : 0.45 + 0.4 * level)
    }
}
