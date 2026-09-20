import SwiftUI
import DesignSystem

/// The placeholder a widget shows while its data is still loading.
///
/// Each kind's skeleton is built from the real widget's own layout — the same
/// figures, rows, axes and marks in the same places at the same sizes — so the
/// card doesn't visibly re-lay-out when the data lands. The per-kind cases
/// below mirror the corresponding content view in `Widgets/Kinds`; when one of
/// those is restyled, its skeleton belongs in the same change.
struct HomeWidgetSkeleton: View {
    let kind: HomeWidgetKind
    let size: HomeWidgetSize

    var body: some View {
        HomeSkeletonPulse {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading \(kind.title)")
        .accessibilityIdentifier(AXID.homeWidgetSkeleton.rawValue + kind.rawValue)
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .needsYou: needsYou
        case .reviewQueue: reviewQueue
        case .looseEnds: looseEnds
        case .streak: streak
        case .today: today
        case .busiestHours: busiestHours
        case .hotFiles: hotFiles
        case .topPermissions: topPermissions
        case .contributions: contributions
        case .weeklyRhythm: weeklyRhythm
        case .agentShare: agentShare
        case .codebaseGrowth: codebaseGrowth
        case .agentScreenshots: HomeSkeletonTiles(size: size)
        }
    }

    // MARK: - Session queues

    /// `NeedsYouWidgetContent`: a bottom-anchored count at small, otherwise
    /// status-dot rows, three of them at medium and six at large.
    @ViewBuilder
    private var needsYou: some View {
        if size == .small {
            HomeSkeletonStack(alignment: .bottom) {
                HomeSkeletonBlock(width: 58, height: 40, radius: FlotillaRadius.control)
                HomeSkeletonBlock(width: 104, height: 10).padding(.top, 4)
                HomeSkeletonBlock(width: 78, height: 8).padding(.top, 3)
            }
        } else {
            VStack(spacing: 6) {
                ForEach(0..<(size == .large ? 6 : 3), id: \.self) { index in
                    HStack(spacing: FlotillaSpacing.small) {
                        Circle().fill(HomeSkeletonStyle.fill).frame(width: 26, height: 26)
                        HomeSkeletonRowText(height: 26) { width in
                            VStack(alignment: .leading, spacing: 3) {
                                HomeSkeletonBlock(width: width * HomeSkeletonRatio.title(index), height: 10)
                                HStack(spacing: 4) {
                                    Circle().fill(HomeSkeletonStyle.fill).frame(width: 10, height: 10)
                                    HomeSkeletonBlock(width: width * HomeSkeletonRatio.subtitle(index), height: 8)
                                }
                            }
                        }
                        HomeSkeletonBlock(width: 26, height: 9)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// `ReviewQueueWidgetContent`: divider-separated rows led by a rounded
    /// agent badge, plus the "Review oldest" footer at large.
    private var reviewQueue: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<(size == .large ? 5 : 2), id: \.self) { index in
                if index > 0 {
                    Divider().overlay(FlotillaColors.separator).padding(.leading, 30)
                }
                HStack(alignment: .top, spacing: FlotillaSpacing.small + 2) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(HomeSkeletonStyle.fill)
                        .frame(width: 22, height: 22)
                    HomeSkeletonRowText(height: 32) { width in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                HomeSkeletonBlock(width: width * HomeSkeletonRatio.title(index) * 0.8, height: 10)
                                Spacer(minLength: 4)
                                HomeSkeletonBlock(width: 24, height: 9)
                            }
                            HStack(spacing: 4) {
                                HomeSkeletonBlock(width: width * HomeSkeletonRatio.subtitle(index) * 0.6, height: 8)
                                Spacer(minLength: 4)
                                HomeSkeletonBlock(width: 52, height: 8)
                            }
                        }
                    }
                }
                .padding(.vertical, 7)
            }
            Spacer(minLength: 0)
            if size == .large {
                HStack {
                    HomeSkeletonBlock(width: 150, height: 9)
                    Spacer()
                    Capsule().fill(HomeSkeletonStyle.fill).frame(width: 104, height: 26)
                }
            }
        }
    }

    /// `LooseEndsWidgetContent`: the three totals, stacked at small and in a
    /// row at medium, where per-project rows with their chips follow.
    @ViewBuilder
    private var looseEnds: some View {
        if size == .small {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in
                    HomeSkeletonFigure(value: 34, valueHeight: 18, caption: 62)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
                HStack(spacing: FlotillaSpacing.large) {
                    ForEach(0..<3, id: \.self) { _ in
                        HomeSkeletonFigure(value: 38, valueHeight: 22, caption: 66)
                    }
                }
                VStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        HStack(spacing: 6) {
                            HomeSkeletonBlock(width: 9, height: 9, radius: 2)
                            HomeSkeletonRowText(height: 13) { width in
                                HomeSkeletonBlock(width: width * HomeSkeletonRatio.subtitle(index) * 0.7, height: 9)
                            }
                            ForEach(0..<2, id: \.self) { _ in
                                Capsule().fill(HomeSkeletonStyle.fill).frame(width: 26, height: 13)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Streak, Today, Busiest hours

    /// `StreakWidgetContent`: the day count over this week's seven dots.
    private var streak: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            HomeSkeletonBlock(width: 54, height: 38, radius: FlotillaRadius.control)
            HStack {
                HomeSkeletonBlock(width: 62, height: 9)
                Spacer(minLength: 4)
                HomeSkeletonBlock(width: 40, height: 8)
            }
            .padding(.top, 6)
            Spacer(minLength: 6)
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { _ in
                    VStack(spacing: 3) {
                        Circle().fill(HomeSkeletonStyle.fill).frame(width: 11, height: 11)
                        HomeSkeletonBlock(width: 5, height: 7)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// `TodayWidgetContent`: commits, the diff line, the sessions line, and
    /// at medium the 24-hour sparkline along the bottom.
    private var today: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 5) {
                HomeSkeletonBlock(width: 44, height: 32, radius: FlotillaRadius.control)
                HomeSkeletonBlock(width: 52, height: 9).padding(.bottom, 4)
            }
            HomeSkeletonBlock(width: 92, height: 9)
            HomeSkeletonBlock(width: 108, height: 8)
            if size == .medium {
                Spacer(minLength: 0)
                HomeSkeletonBars(count: 24, barWidth: 4, height: 22, cornerRadius: 1.5)
            }
        }
    }

    /// `BusiestHoursWidgetContent`: the summary line, then seven weekday rows
    /// of 24 dots behind a label column, with the hour axis underneath.
    private var busiestHours: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HomeSkeletonBlock(width: 96, height: 8)
                Spacer()
                HomeSkeletonBlock(width: 84, height: 8)
            }
            GeometryReader { proxy in
                let labelWidth: CGFloat = 12
                let axisHeight: CGFloat = 10
                let pitch = min((proxy.size.width - labelWidth) / 24, (proxy.size.height - axisHeight) / 7)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<7, id: \.self) { _ in
                        HStack(spacing: 0) {
                            HomeSkeletonBlock(width: 6, height: 7)
                                .frame(width: labelWidth, alignment: .leading)
                            ForEach(0..<24, id: \.self) { hour in
                                Circle()
                                    .fill(HomeSkeletonStyle.fill)
                                    .frame(width: pitch, height: pitch)
                                    // The real dots scale with their commit
                                    // count; these vary the same way so the
                                    // field doesn't read as a uniform mesh.
                                    .scaleEffect(0.4 + 0.35 * HomeSkeletonRatio.dot(hour))
                            }
                        }
                    }
                    HStack(spacing: 0) {
                        Color.clear.frame(width: labelWidth, height: axisHeight)
                        ForEach(0..<24, id: \.self) { hour in
                            Group {
                                if hour % 6 == 0 { HomeSkeletonBlock(width: 7, height: 6) }
                            }
                            .frame(width: pitch, height: axisHeight, alignment: .leading)
                        }
                    }
                }
                .frame(width: labelWidth + pitch * 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: - Ranked lists

    /// `HotFilesWidgetContent`: heat pill, file name with its directory, and
    /// the edit count on the right.
    private var hotFiles: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<(size == .large ? 13 : 5), id: \.self) { index in
                HStack(spacing: 7) {
                    Capsule().fill(HomeSkeletonStyle.fill).frame(width: 30, height: 5)
                    HomeSkeletonRowText(height: 9) { width in
                        HomeSkeletonBlock(width: width * HomeSkeletonRatio.title(index), height: 9)
                    }
                    HomeSkeletonBlock(width: 22, height: 9)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// `TopPermissionsWidgetContent`: the pattern, its share bar and count.
    @ViewBuilder
    private var topPermissions: some View {
        if size == .small {
            HomeSkeletonStack(alignment: .bottom) {
                HomeSkeletonBlock(width: 50, height: 34, radius: FlotillaRadius.control)
                HomeSkeletonBlock(width: 96, height: 9).padding(.top, 4)
                HomeSkeletonBlock(width: 70, height: 8).padding(.top, 3)
            }
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(0..<5, id: \.self) { index in
                    HStack(spacing: 7) {
                        HomeSkeletonBlock(width: 9, height: 9, radius: 2).frame(width: 12)
                        HomeSkeletonBlock(width: 150 * HomeSkeletonRatio.title(index), height: 9)
                            .frame(width: 150, alignment: .leading)
                        GeometryReader { proxy in
                            Capsule()
                                .fill(HomeSkeletonStyle.fill)
                                .frame(width: proxy.size.width * HomeSkeletonRatio.bar(index), height: 6)
                                .frame(maxHeight: .infinity)
                        }
                        .frame(height: 9)
                        HomeSkeletonBlock(width: 20, height: 9)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Charts

    /// `ContributionHeatmap`: the stats column beside the grid at wide, the
    /// one-line summary above it otherwise — with the month labels on top.
    private var contributions: some View {
        GeometryReader { proxy in
            let monthHeight: CGFloat = 12
            let summaryHeight: CGFloat = 14
            if size == .wide {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        HomeSkeletonFigure(value: 52, valueHeight: 18, caption: 54)
                        HStack(spacing: FlotillaSpacing.medium) {
                            HomeSkeletonFigure(value: 34, valueHeight: 18, caption: 42)
                            HomeSkeletonFigure(value: 34, valueHeight: 18, caption: 50)
                        }
                        Spacer(minLength: 2)
                        HomeSkeletonBlock(width: 118, height: 9)
                    }
                    .frame(width: 138, alignment: .leading)

                    Rectangle()
                        .fill(FlotillaColors.separator)
                        .frame(width: 1)
                        .padding(.vertical, 2)
                        .padding(.horizontal, FlotillaSpacing.medium)

                    heatmapGrid(
                        available: CGSize(width: proxy.size.width - 138 - FlotillaSpacing.medium * 2 - 1,
                                          height: proxy.size.height),
                        monthHeight: monthHeight
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: FlotillaSpacing.medium) {
                        HomeSkeletonBlock(width: 78, height: 9)
                        HomeSkeletonBlock(width: 56, height: 9)
                        Spacer(minLength: 4)
                        HomeSkeletonBlock(width: 96, height: 9)
                    }
                    .frame(height: summaryHeight)
                    heatmapGrid(
                        available: CGSize(width: proxy.size.width, height: proxy.size.height - summaryHeight - 6),
                        monthHeight: monthHeight
                    )
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
        }
    }

    /// Month labels over seven rows of week columns, cells sized from the
    /// space available exactly as `ContributionHeatmap.layout` sizes them.
    private func heatmapGrid(available: CGSize, monthHeight: CGFloat) -> some View {
        let gap: CGFloat = 3
        let gridHeight = max(available.height - monthHeight - 4, 1)
        let cell = min(22, max(8, (gridHeight - 6 * gap) / 7))
        let weeks = max(1, min(53, Int((available.width + gap) / (cell + gap))))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                ForEach(0..<max(1, weeks / 4), id: \.self) { _ in
                    HomeSkeletonBlock(width: 18, height: 8)
                        .frame(width: (cell + gap) * 4, alignment: .leading)
                }
            }
            .frame(height: monthHeight, alignment: .topLeading)
            HStack(alignment: .top, spacing: gap) {
                ForEach(0..<weeks, id: \.self) { week in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { weekday in
                            RoundedRectangle(cornerRadius: min(3, cell / 4), style: .continuous)
                                .fill(HomeSkeletonStyle.fill)
                                .frame(width: cell, height: cell)
                                // The real heatmap is mostly faint with a few
                                // bright days; keep that texture.
                                .opacity(HomeSkeletonRatio.cell(week, weekday))
                        }
                    }
                }
            }
        }
    }

    /// `RhythmChartContent`: the added/removed figures over a chart of
    /// additions above the baseline and deletions mirrored below it.
    private var weeklyRhythm: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            HStack(spacing: FlotillaSpacing.xLarge) {
                HomeSkeletonFigure(value: 48, valueHeight: 18, caption: 38)
                HomeSkeletonFigure(value: 48, valueHeight: 18, caption: 52)
                Spacer(minLength: 0)
            }
            HomeSkeletonPlot(yAxisLabels: 4, xAxisLabels: 4) {
                HomeSkeletonMirroredBars()
            }
        }
    }

    /// `AgentShareWidgetContent`: the donut at the size the card allows, the
    /// legend beside it, and at large the per-agent lines table below.
    @ViewBuilder
    private var agentShare: some View {
        switch size {
        case .small:
            HomeSkeletonRing()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .large:
            VStack(spacing: FlotillaSpacing.medium) {
                HStack(alignment: .center, spacing: FlotillaSpacing.xLarge) {
                    HomeSkeletonRing().frame(maxWidth: 150)
                    agentShareLegend
                }
                .frame(maxHeight: .infinity)
                Divider().opacity(0.5)
                VStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        HStack(spacing: FlotillaSpacing.small) {
                            HomeSkeletonBlock(width: 74, height: 9).frame(width: 90, alignment: .leading)
                            HomeSkeletonBlock(width: 62, height: 8)
                            Spacer(minLength: 4)
                            HomeSkeletonBlock(width: 34, height: 9)
                            HomeSkeletonBlock(width: 34, height: 9)
                        }
                    }
                }
            }
        default:
            HStack(alignment: .center, spacing: FlotillaSpacing.xLarge) {
                HomeSkeletonRing()
                agentShareLegend
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var agentShareLegend: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: FlotillaSpacing.small) {
                    Circle().fill(HomeSkeletonStyle.fill).frame(width: 15, height: 15)
                    HomeSkeletonBlock(width: 70 * HomeSkeletonRatio.title(index), height: 9)
                    Spacer(minLength: FlotillaSpacing.small)
                    HomeSkeletonBlock(width: 16, height: 9)
                    HomeSkeletonBlock(width: 30, height: 9)
                    Circle().fill(HomeSkeletonStyle.fill).frame(width: 7, height: 7)
                }
            }
            Divider().opacity(0.6)
            HomeSkeletonBlock(width: 170, height: 8)
        }
    }

    /// `GrowthChartContent`: the project scope chips, the net-lines headline,
    /// then the cumulative area chart with its axes — an area rising to the
    /// right, not a bar chart.
    private var codebaseGrowth: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(HomeSkeletonStyle.fill)
                        .frame(width: [86, 74, 92, 68][index], height: 24)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 24, alignment: .leading)
            .clipped()

            HStack(alignment: .center, spacing: FlotillaSpacing.small) {
                HomeSkeletonBlock(width: 54, height: 17, radius: 4)
                HomeSkeletonBlock(width: 122, height: 9)
                Spacer(minLength: 0)
            }

            HomeSkeletonPlot(yAxisLabels: 3, xAxisLabels: 5) {
                HomeSkeletonAreaChart()
            }
        }
    }
}

// MARK: - Pulse

enum HomeSkeletonStyle {
    /// Placeholder shapes are drawn **opaque** and dimmed by `HomeSkeletonPulse`.
    /// They have to be opaque because the pulse masks its highlight band with
    /// them, and a mask takes its coverage from the alpha channel — filling
    /// the shapes at the tint they're finally shown in would multiply the
    /// band down to nothing and there'd be no visible flash at all.
    static let fill = FlotillaColors.textPrimary

    /// Resting tint, and the range the pulse brightens through.
    static let dim: Double = 0.10
    static let bright: Double = 0.24
    /// What Reduce Motion shows instead of the pulse.
    static let resting: Double = 0.16
    /// Peak brightness of the sweeping band, over the dimmed shapes.
    static let highlight = FlotillaColors.textPrimary.opacity(0.3)
    static let period: Double = 1.5
}

/// The classic loading pulse: the placeholder shapes breathe between dim and
/// bright while a soft band sweeps across them.
///
/// Driven by `TimelineView(.animation)` rather than a `repeatForever`
/// animation kicked off in `onAppear` — that kind of animation silently fails
/// to start when the view is inserted inside an enclosing transaction, which
/// is exactly how a skeleton appears (mid-reflow, as the grid lays out). The
/// timeline is unconditional: if the skeleton is on screen, it is pulsing.
///
/// The band is drawn over the whole group and masked back to the shapes, so
/// one clock drives every bar in a card instead of each pulsing on its own.
/// Under Reduce Motion nothing animates — the resting placeholders alone
/// already say the content isn't there yet.
struct HomeSkeletonPulse<Content: View>: View {
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            content.opacity(HomeSkeletonStyle.resting)
        } else {
            // 30fps: plenty for a soft pulse, and a quarter of the redraws a
            // display-rate timeline would cost across a gridful of skeletons —
            // the wide heatmap alone is several hundred cells.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: HomeSkeletonStyle.period)
                    / HomeSkeletonStyle.period
                // Breathes dim → bright → dim, with a band sweeping across on
                // the same clock. The mask is a second, full-alpha copy of the
                // shapes, so both the dimming and the band stay inside them.
                let wave = 0.5 - 0.5 * cos(2 * .pi * t)
                content
                    .opacity(HomeSkeletonStyle.dim + (HomeSkeletonStyle.bright - HomeSkeletonStyle.dim) * wave)
                    .overlay { sweep(progress: t) }
                    .mask { content }
            }
        }
    }

    private func sweep(progress: Double) -> some View {
        GeometryReader { proxy in
            let band = max(proxy.size.width * 0.45, 80)
            LinearGradient(
                colors: [.clear, HomeSkeletonStyle.highlight, .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: band)
            .offset(x: -band + progress * (proxy.size.width + band * 2))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Variation

/// Fixed ratio tables. Placeholder widths have to vary — a column of
/// identical bars reads as a table, not as absent text — but they must not
/// change between redraws, and the pulse redraws every frame.
enum HomeSkeletonRatio {
    private static let titles: [CGFloat] = [0.74, 0.52, 0.86, 0.45, 0.67, 0.58, 0.79, 0.49, 0.71, 0.55, 0.83, 0.47, 0.63]
    private static let subtitles: [CGFloat] = [0.45, 0.62, 0.38, 0.55, 0.48, 0.66, 0.41, 0.58, 0.5, 0.35, 0.6, 0.43, 0.52]
    private static let bars: [CGFloat] = [0.92, 0.7, 0.55, 0.38, 0.24, 0.62, 0.46, 0.3]
    private static let dots: [CGFloat] = [0.1, 0.05, 0, 0, 0.15, 0.3, 0.55, 0.7, 0.9, 1, 0.85, 0.6,
                                          0.45, 0.75, 0.95, 0.8, 0.65, 0.5, 0.7, 0.9, 0.6, 0.35, 0.2, 0.1]

    static func title(_ index: Int) -> CGFloat { titles[index % titles.count] }
    static func subtitle(_ index: Int) -> CGFloat { subtitles[index % subtitles.count] }
    static func bar(_ index: Int) -> CGFloat { bars[index % bars.count] }
    static func dot(_ index: Int) -> CGFloat { dots[index % dots.count] }

    /// Heatmap texture: mostly faint, occasionally bright.
    static func cell(_ week: Int, _ weekday: Int) -> Double {
        let hash = (week &* 7 &+ weekday &* 13) % 11
        return [0.4, 0.4, 0.4, 0.4, 0.9, 0.4, 0.4, 0.65, 0.4, 0.4, 0.4][hash]
    }
}

// MARK: - Primitives

/// A plain placeholder slab — the unit every skeleton is built from.
struct HomeSkeletonBlock: View {
    var width: CGFloat?
    var height: CGFloat
    var radius: CGFloat = 3

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(HomeSkeletonStyle.fill)
            .frame(width: width, height: height)
    }
}

/// A headline number over its caption, matching `HomeWidgetHeadlineFigure`.
struct HomeSkeletonFigure: View {
    var value: CGFloat
    var valueHeight: CGFloat
    var caption: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HomeSkeletonBlock(width: value, height: valueHeight, radius: 4)
            HomeSkeletonBlock(width: caption, height: 8)
        }
    }
}

/// Pins its content to the top or bottom of the card, the way the widgets
/// that lead with a `Spacer` pin theirs.
struct HomeSkeletonStack<Content: View>: View {
    var alignment: VerticalAlignment = .bottom
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if alignment == .bottom { Spacer(minLength: 0) }
            content
            if alignment == .top { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// A row's text column: takes whatever width is left over between the row's
/// fixed leading and trailing elements, and hands it to `content` so lines can
/// be sized as a fraction of it. Ratios can't go into `frame(maxWidth:)` —
/// that takes points, and a 0.74 there is three quarters of one point.
struct HomeSkeletonRowText<Content: View>: View {
    var height: CGFloat
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        GeometryReader { proxy in
            content(proxy.size.width)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .frame(height: height)
    }
}

/// A chart frame: tick labels down the leading edge and along the bottom,
/// with the plot itself in the remaining space.
struct HomeSkeletonPlot<Plot: View>: View {
    var yAxisLabels: Int
    var xAxisLabels: Int
    @ViewBuilder let plot: Plot

    private static var axisWidth: CGFloat { 22 }
    private static var axisHeight: CGFloat { 12 }

    var body: some View {
        HStack(spacing: 4) {
            VStack(spacing: 0) {
                ForEach(0..<yAxisLabels, id: \.self) { index in
                    HomeSkeletonBlock(width: 16, height: 7)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    if index < yAxisLabels - 1 { Spacer(minLength: 0) }
                }
                Spacer(minLength: 0).frame(height: Self.axisHeight)
            }
            .frame(width: Self.axisWidth)

            VStack(spacing: 4) {
                plot
                HStack(spacing: 0) {
                    ForEach(0..<xAxisLabels, id: \.self) { index in
                        HomeSkeletonBlock(width: 22, height: 7)
                        if index < xAxisLabels - 1 { Spacer(minLength: 0) }
                    }
                }
                .frame(height: Self.axisHeight - 4)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// A run of bars standing on the baseline; `count` of them, or as many as
/// fit when it isn't given.
struct HomeSkeletonBars: View {
    var count: Int?
    var barWidth: CGFloat = 8
    var height: CGFloat?
    var cornerRadius: CGFloat = 2

    private static let ratios: [CGFloat] = [0.38, 0.66, 0.5, 0.88, 0.32, 0.74, 0.57, 0.95, 0.44, 0.7, 0.27, 0.82, 0.6, 0.48, 0.9, 0.35]

    var body: some View {
        GeometryReader { proxy in
            let spacing = max(2, barWidth * 0.5)
            let fits = max(1, Int((proxy.size.width + spacing) / (barWidth + spacing)))
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<min(count ?? fits, fits), id: \.self) { index in
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(HomeSkeletonStyle.fill)
                        .frame(width: barWidth, height: max(3, proxy.size.height * Self.ratios[index % Self.ratios.count]))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
        .frame(height: height)
    }
}

/// Additions above a baseline, deletions mirrored below — the rhythm chart's
/// shape, with the baseline rule the real chart draws.
struct HomeSkeletonMirroredBars: View {
    private static let up: [CGFloat] = [0.5, 0.86, 0.34, 0.68, 0.92, 0.44, 0.6, 0.28, 0.76, 0.52, 0.4, 0.8]
    private static let down: [CGFloat] = [0.3, 0.5, 0.18, 0.42, 0.62, 0.24, 0.36, 0.14, 0.46, 0.32, 0.22, 0.4]

    var body: some View {
        GeometryReader { proxy in
            // The baseline sits where the chart's zero rule sits: additions
            // take the upper two thirds, deletions the lower third.
            let baseline = proxy.size.height * 0.62
            let barWidth = min(max((proxy.size.width / 28) * 0.55, 3), 16)
            let spacing = max(2, proxy.size.width / 28 - barWidth)
            let count = max(1, Int(proxy.size.width / (barWidth + spacing)))
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(FlotillaColors.separatorStrong)
                    .frame(height: 1)
                    .offset(y: baseline)
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(0..<count, id: \.self) { index in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            bar(baseline * Self.up[index % Self.up.count], radius: .top)
                            bar((proxy.size.height - baseline) * Self.down[index % Self.down.count], radius: .bottom)
                            Spacer(minLength: 0)
                        }
                        .frame(height: proxy.size.height)
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    private enum BarEnd { case top, bottom }

    private func bar(_ length: CGFloat, radius end: BarEnd) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: end == .top ? 3 : 0,
            bottomLeadingRadius: end == .bottom ? 3 : 0,
            bottomTrailingRadius: end == .bottom ? 3 : 0,
            topTrailingRadius: end == .top ? 3 : 0,
            style: .continuous
        )
        .fill(HomeSkeletonStyle.fill)
        .frame(height: max(2, length))
    }
}

/// A cumulative curve rising to the right with its area filled underneath —
/// the growth chart's silhouette, including the zero rule at the bottom.
struct HomeSkeletonAreaChart: View {
    /// Normalized heights, monotonically rising the way a cumulative total
    /// does, with the plateaus a real one has.
    private static let points: [CGFloat] = [0.06, 0.1, 0.11, 0.2, 0.28, 0.3, 0.42, 0.55, 0.58, 0.72, 0.78, 0.92]

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(FlotillaColors.separatorStrong)
                    .frame(height: 1)
                HomeSkeletonCurve(points: Self.points, closed: true)
                    .fill(LinearGradient(
                        colors: [HomeSkeletonStyle.fill.opacity(0.55), HomeSkeletonStyle.fill.opacity(0.12)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                HomeSkeletonCurve(points: Self.points, closed: false)
                    .stroke(HomeSkeletonStyle.fill, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// The curve through `points`, smoothed, optionally closed down to the
/// baseline so it can be filled as an area.
struct HomeSkeletonCurve: Shape {
    let points: [CGFloat]
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        guard points.count > 1 else { return Path() }
        let step = rect.width / CGFloat(points.count - 1)
        let resolved = points.enumerated().map { index, value in
            CGPoint(x: rect.minX + CGFloat(index) * step, y: rect.maxY - value * rect.height)
        }
        var path = Path()
        path.move(to: resolved[0])
        for index in 1..<resolved.count {
            let previous = resolved[index - 1]
            let current = resolved[index]
            // Horizontal control points: a smooth curve that never overshoots
            // above or below its own points, like `.monotone` interpolation.
            let midX = (previous.x + current.x) / 2
            path.addCurve(
                to: current,
                control1: CGPoint(x: midX, y: previous.y),
                control2: CGPoint(x: midX, y: current.y)
            )
        }
        if closed {
            path.addLine(to: CGPoint(x: resolved[resolved.count - 1].x, y: rect.maxY))
            path.addLine(to: CGPoint(x: resolved[0].x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// The donut chart's ring, sized to the space it's given the way the real
/// ring is — square, as large as the card's height allows.
struct HomeSkeletonRing: View {
    var body: some View {
        GeometryReader { proxy in
            let diameter = max(40, min(proxy.size.width, proxy.size.height))
            Circle()
                .strokeBorder(HomeSkeletonStyle.fill, lineWidth: diameter * 0.25)
                .frame(width: diameter, height: diameter)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxHeight: .infinity)
    }
}

/// The screenshot feed's tiles, in the arrangement its content uses.
struct HomeSkeletonTiles: View {
    let size: HomeWidgetSize

    var body: some View {
        switch size {
        case .medium:
            HStack(spacing: FlotillaSpacing.small) {
                tile
                tile
            }
        case .wide:
            HStack(spacing: FlotillaSpacing.small) {
                ForEach(0..<4, id: \.self) { _ in tile }
            }
        default:
            Grid(horizontalSpacing: FlotillaSpacing.small, verticalSpacing: FlotillaSpacing.small) {
                GridRow { tile; tile }
                GridRow { tile; tile }
            }
        }
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
            .fill(HomeSkeletonStyle.fill)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
#Preview("Widget skeletons") {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
            ForEach(HomeWidgetKind.allCases) { kind in
                HomeWidgetCard(kind: kind) {
                    HomeWidgetSkeleton(kind: kind, size: kind.defaultSize)
                }
                .frame(height: 180)
            }
        }
        .padding(24)
    }
    .background(FlotillaColors.canvas)
}
#endif
