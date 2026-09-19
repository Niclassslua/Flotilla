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
                HStack {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: [.yellow, FlotillaColors.accent], startPoint: .top, endPoint: .bottom))
                    Spacer()
                    Text("best \(best)d")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
                Spacer(minLength: 0)
                Text("\(current)")
                    .font(.system(size: 46, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .padding(.bottom, -4)
                Text("day streak")
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textSecondary)
                Spacer(minLength: 0)
                week(activity: activity)
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
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
            return AnyView(ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60))
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
                Capsule()
                    .fill(hourly[hour] == 0 ? FlotillaColors.textPrimary.opacity(0.08) : FlotillaColors.accent)
                    .frame(height: max(3, 22 * CGFloat(hourly[hour]) / CGFloat(peak)))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 22, alignment: .bottom)
    }
}

// MARK: - Busiest Hours

struct BusiestHoursWidgetContent: View {
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

    var body: some View {
        if total == 0 {
            HomeWidgetAllClearState(message: "No commits in this window.")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Spacer()
                    Text("Peak: \(days[busiest.day]) \(busiest.hour):00")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(FlotillaColors.accent)
                }
                VStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { day in
                        HStack(spacing: 2) {
                            Text(days[day].prefix(1))
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(FlotillaColors.textTertiary)
                                .frame(width: 10, alignment: .leading)
                            ForEach(0..<24, id: \.self) { hour in dot(grid[day][hour]) }
                        }
                    }
                    HStack(spacing: 2) {
                        Color.clear.frame(width: 10, height: 1)
                        ForEach(0..<24, id: \.self) { hour in
                            Text(hour % 6 == 0 ? "\(hour)" : "")
                                .font(.system(size: 7, weight: .medium))
                                .foregroundStyle(FlotillaColors.textTertiary)
                                .fixedSize()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Spacer(minLength: 0)
                Text("\(eveningShare)% of commits land after 8 pm")
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
        }
    }

    private func dot(_ count: Int) -> some View {
        let level = Double(count) / Double(max(peak, 1))
        return Circle()
            .fill(count == 0 ? FlotillaColors.textPrimary.opacity(0.06) : FlotillaColors.accent.opacity(0.25 + 0.75 * level))
            .scaleEffect(count == 0 ? 0.45 : 0.5 + 0.5 * level)
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
    }
}
