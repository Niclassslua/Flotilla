import SwiftUI
import DesignSystem

/// The placeholder a widget shows while its data is still loading.
///
/// Rather than mimicking each widget's exact chart, a skeleton picks one of
/// a handful of archetypes — rows, bars, a grid, a ring, tiles — and sizes
/// it to the card it's given. That's enough for the card to read as "content
/// is coming here" without a per-kind drawing that goes subtly wrong every
/// time the real widget is restyled.
struct HomeWidgetSkeleton: View {
    let kind: HomeWidgetKind
    let size: HomeWidgetSize

    var body: some View {
        HomeSkeletonPulse {
            GeometryReader { proxy in
                shape(in: proxy.size)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading \(kind.title)")
        .accessibilityIdentifier(AXID.homeWidgetSkeleton.rawValue + kind.rawValue)
    }

    /// Which archetype stands in for this kind at this size.
    private enum Archetype {
        /// One headline number over a caption — every widget whose small
        /// size is a single big figure.
        case figure
        /// A list of rows; `avatar` for the ones that lead with a status dot
        /// or provider mark.
        case rows(avatar: Bool)
        /// A bar chart filling the card.
        case bars
        /// A bar chart under a headline figure.
        case figureAndBars
        /// The heatmap-style cell grid.
        case grid(rows: Int)
        /// A centered ring, with rows beside it when there's width for them.
        case ring(withRows: Bool)
        case tiles
    }

    private var archetype: Archetype {
        switch kind {
        case .needsYou, .looseEnds, .topPermissions:
            size == .small ? .figure : .rows(avatar: kind == .needsYou)
        case .reviewQueue:
            .rows(avatar: true)
        case .hotFiles:
            .rows(avatar: false)
        case .streak:
            .figure
        case .today:
            size == .small ? .figure : .figureAndBars
        case .busiestHours:
            .grid(rows: 7)
        case .contributions:
            .grid(rows: 7)
        case .weeklyRhythm, .codebaseGrowth:
            .bars
        case .agentShare:
            .ring(withRows: size != .small)
        case .agentScreenshots:
            .tiles
        }
    }

    @ViewBuilder
    private func shape(in available: CGSize) -> some View {
        switch archetype {
        case .figure:
            HomeSkeletonFigure()
        case .rows(let avatar):
            HomeSkeletonRows(avatar: avatar, height: available.height)
        case .bars:
            HomeSkeletonBars(height: available.height)
        case .figureAndBars:
            VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
                HomeSkeletonFigure(compact: true)
                Spacer(minLength: 0)
                HomeSkeletonBars(height: min(34, available.height * 0.35))
            }
        case .grid(let rows):
            HomeSkeletonGrid(rows: rows, available: available)
        case .ring(let withRows):
            HStack(spacing: FlotillaSpacing.xLarge) {
                HomeSkeletonRing(diameter: min(available.height, withRows ? 120 : available.width))
                if withRows, available.width > 230 {
                    HomeSkeletonRows(avatar: false, height: min(available.height, 86))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: withRows ? .leading : .center)
        case .tiles:
            HomeSkeletonTiles(size: size)
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
            TimelineView(.animation) { context in
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

// MARK: - Archetypes

/// A headline number over a caption line, centered in the card the way the
/// widgets that show one big figure center theirs.
struct HomeSkeletonFigure: View {
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !compact { Spacer(minLength: 0) }
            HomeSkeletonBlock(width: compact ? 84 : 72, height: compact ? 28 : 38, radius: FlotillaRadius.control)
            HomeSkeletonBlock(width: 96, height: 9)
            HomeSkeletonBlock(width: 64, height: 8)
            if !compact { Spacer(minLength: 0) }
        }
        // Fills the card so the spacers have somewhere to expand into and
        // the figure sits centered, the way the real headline figures do.
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity, alignment: .leading)
    }
}

/// List rows, as many as the card has room for — so a large card fills and a
/// medium one doesn't overflow, without either being a hardcoded count.
struct HomeSkeletonRows: View {
    var avatar: Bool
    /// Space the rows may occupy.
    var height: CGFloat

    private static let spacing: CGFloat = 8
    /// Fixed widths, so rows don't reshuffle as the pulse redraws them.
    private static let widths: [CGFloat] = [0.74, 0.52, 0.86, 0.45, 0.67, 0.58, 0.79, 0.49, 0.71, 0.55, 0.83, 0.47]

    private var rowHeight: CGFloat { avatar ? 26 : 12 }

    private var count: Int {
        max(1, min(Self.widths.count, Int((height + Self.spacing) / (rowHeight + Self.spacing))))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: FlotillaSpacing.small) {
                    if avatar {
                        Circle().fill(HomeSkeletonStyle.fill).frame(width: rowHeight, height: rowHeight)
                    }
                    GeometryReader { proxy in
                        VStack(alignment: .leading, spacing: 5) {
                            HomeSkeletonBlock(width: proxy.size.width * Self.widths[index % Self.widths.count], height: 9)
                            if avatar {
                                HomeSkeletonBlock(width: proxy.size.width * 0.42, height: 7)
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: rowHeight)
                    HomeSkeletonBlock(width: 26, height: 9)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A bar chart standing on the card's baseline, as many bars as fit.
struct HomeSkeletonBars: View {
    var height: CGFloat
    var barWidth: CGFloat = 8

    private static let ratios: [CGFloat] = [0.38, 0.66, 0.5, 0.88, 0.32, 0.74, 0.57, 0.95, 0.44, 0.7, 0.27, 0.82, 0.6, 0.48, 0.9, 0.35]

    var body: some View {
        GeometryReader { proxy in
            let spacing = max(3, barWidth * 0.55)
            let count = max(1, Int((proxy.size.width + spacing) / (barWidth + spacing)))
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(HomeSkeletonStyle.fill)
                        .frame(height: max(4, proxy.size.height * Self.ratios[index % Self.ratios.count]))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
        .frame(height: height)
    }
}

/// The heatmap's cells: a fixed number of rows, as many columns as fit, with
/// the cell size derived from the height so the grid fills the card.
struct HomeSkeletonGrid: View {
    var rows: Int
    var available: CGSize

    private static let gap: CGFloat = 3

    var body: some View {
        let cell = max(6, min(14, (available.height - CGFloat(rows - 1) * Self.gap) / CGFloat(rows)))
        let columns = max(1, Int((available.width + Self.gap) / (cell + Self.gap)))
        HStack(alignment: .top, spacing: Self.gap) {
            ForEach(0..<columns, id: \.self) { _ in
                VStack(spacing: Self.gap) {
                    ForEach(0..<rows, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(HomeSkeletonStyle.fill)
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The donut chart's ring, at the size the real ring takes: as large as the
/// card's height allows, not a fixed badge in the corner.
struct HomeSkeletonRing: View {
    var diameter: CGFloat

    var body: some View {
        Circle()
            .strokeBorder(HomeSkeletonStyle.fill, lineWidth: max(8, diameter * 0.18))
            .frame(width: max(40, diameter), height: max(40, diameter))
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

/// A plain placeholder slab — the unit every archetype is built from.
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
