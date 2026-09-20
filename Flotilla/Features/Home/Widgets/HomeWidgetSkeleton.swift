import SwiftUI
import DesignSystem

/// The placeholder a widget shows while its data is still loading.
///
/// Every kind gets a skeleton shaped like the content that replaces it —
/// rows where rows land, a grid where the heatmap lands — so the card
/// doesn't visibly re-lay-out when the real numbers arrive. A spinner in a
/// 2×2 card says only "wait"; this says what's coming.
struct HomeWidgetSkeleton: View {
    let kind: HomeWidgetKind
    let size: HomeWidgetSize

    var body: some View {
        HomeWidgetShimmer {
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
        case .needsYou:
            if size == .small {
                HomeSkeletonFigure(caption: 78, detail: 54)
            } else {
                HomeSkeletonRows(count: size == .large ? 6 : 3, spacing: 6, avatar: 26)
            }
        case .reviewQueue:
            VStack(alignment: .leading, spacing: 6) {
                HomeSkeletonRows(count: size == .large ? 5 : 2, spacing: 6, avatar: 26)
                if size == .large {
                    Spacer(minLength: 0)
                    HomeSkeletonBar(width: 132, height: 20, radius: FlotillaRadius.control)
                }
            }
        case .looseEnds:
            if size == .small {
                HomeSkeletonFigure(caption: 70, detail: 48)
            } else {
                HomeSkeletonRows(count: 3, spacing: 7, avatar: 20)
            }
        case .streak:
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                HomeSkeletonBar(width: 62, height: 34, radius: FlotillaRadius.control)
                HomeSkeletonBar(width: 96, height: 9)
                    .padding(.top, 6)
                Spacer(minLength: 6)
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { _ in
                        VStack(spacing: 3) {
                            Circle().fill(HomeSkeletonStyle.fill).frame(width: 11, height: 11)
                            HomeSkeletonBar(width: 6, height: 7)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        case .today:
            VStack(alignment: .leading, spacing: 5) {
                HomeSkeletonBar(width: 88, height: 28, radius: FlotillaRadius.control)
                HomeSkeletonBar(width: 104, height: 9)
                HomeSkeletonBar(width: 82, height: 8)
                if size == .medium {
                    Spacer(minLength: 0)
                    HomeSkeletonColumns(count: 24, width: 4, height: 22)
                }
            }
        case .busiestHours:
            VStack(alignment: .leading, spacing: 4) {
                HomeSkeletonBar(width: 104, height: 8)
                HomeSkeletonDotGrid(rows: 7, columns: 24)
            }
        case .hotFiles:
            HomeSkeletonRows(count: size == .large ? 12 : 5, spacing: 6, avatar: 0, leadingPill: 30)
        case .topPermissions:
            if size == .small {
                HomeSkeletonFigure(caption: 72, detail: 50)
            } else {
                HomeSkeletonRows(count: 5, spacing: 7, avatar: 0, leadingPill: 12)
            }
        case .contributions:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: FlotillaSpacing.medium) {
                    HomeSkeletonBar(width: 90, height: 22, radius: FlotillaRadius.control)
                    HomeSkeletonBar(width: 76, height: 22, radius: FlotillaRadius.control)
                    HomeSkeletonBar(width: 76, height: 22, radius: FlotillaRadius.control)
                }
                HomeSkeletonDotGrid(rows: 7, columns: size == .wide ? 40 : 20, cell: 10, gap: 3)
            }
        case .weeklyRhythm:
            VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
                HStack(spacing: FlotillaSpacing.xLarge) {
                    HomeSkeletonBar(width: 74, height: 20, radius: FlotillaRadius.control)
                    HomeSkeletonBar(width: 74, height: 20, radius: FlotillaRadius.control)
                }
                HomeSkeletonMirroredColumns(count: 28, width: 6, height: 56)
            }
        case .agentShare:
            switch size {
            case .small:
                HomeSkeletonDonut()
            case .large:
                VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
                    HStack(spacing: FlotillaSpacing.large) {
                        HomeSkeletonDonut()
                        HomeSkeletonRows(count: 3, spacing: 6, avatar: 0, leadingPill: 10)
                    }
                    HomeSkeletonRows(count: 3, spacing: 6, avatar: 0, leadingPill: 10)
                }
            default:
                HStack(spacing: FlotillaSpacing.large) {
                    HomeSkeletonDonut()
                    HomeSkeletonRows(count: 3, spacing: 6, avatar: 0, leadingPill: 10)
                }
            }
        case .codebaseGrowth:
            VStack(alignment: .leading, spacing: 6) {
                HomeSkeletonBar(width: 118, height: 22, radius: FlotillaRadius.control)
                HomeSkeletonColumns(count: size == .medium ? 16 : 34, width: 10, height: 48)
                HomeSkeletonBar(width: 148, height: 8)
            }
        case .agentScreenshots:
            HomeSkeletonTiles(size: size)
        }
    }
}

// MARK: - Shimmer

enum HomeSkeletonStyle {
    /// The placeholder body — a flat tint of the card's own foreground, so
    /// it reads as "absent" rather than as a real, dimmed value.
    static let fill = FlotillaColors.textPrimary.opacity(0.16)
    static let highlight = FlotillaColors.textPrimary.opacity(0.28)
}

/// Sweeps a soft highlight across whatever placeholder shapes it wraps.
///
/// The band is drawn over the group and then masked back to the shapes, so
/// one animation drives every bar in a card instead of each pulsing on its
/// own clock. Under Reduce Motion it doesn't animate at all — the static
/// placeholders alone already say the content isn't there yet.
struct HomeWidgetShimmer<Content: View>: View {
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    private static var travel: Animation {
        .linear(duration: 1.4).repeatForever(autoreverses: false)
    }

    var body: some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, HomeSkeletonStyle.highlight, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: max(proxy.size.width * 0.55, 60))
                        .offset(x: phase * (proxy.size.width + 60))
                    }
                    .allowsHitTesting(false)
                }
            }
            .mask { content }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(Self.travel) { phase = 1 }
            }
    }
}

// MARK: - Primitives

struct HomeSkeletonBar: View {
    var width: CGFloat?
    var height: CGFloat
    var radius: CGFloat = 3

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(HomeSkeletonStyle.fill)
            .frame(width: width, height: height)
    }
}

/// A headline number with a caption under it — the shape every "one big
/// figure" widget takes at `.small`.
struct HomeSkeletonFigure: View {
    var caption: CGFloat
    var detail: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Spacer(minLength: 0)
            HomeSkeletonBar(width: 66, height: 36, radius: FlotillaRadius.control)
            HomeSkeletonBar(width: caption, height: 9)
            if let detail {
                HomeSkeletonBar(width: detail, height: 8)
            }
        }
    }
}

/// List rows: an optional leading circle or pill, a title line of varying
/// width, and a trailing value block.
struct HomeSkeletonRows: View {
    var count: Int
    var spacing: CGFloat
    var avatar: CGFloat
    var leadingPill: CGFloat?

    /// Fixed so the rows don't reshuffle on every redraw — a skeleton that
    /// changes width as it shimmers looks like loading content, not a
    /// placeholder.
    private static let widths: [CGFloat] = [0.72, 0.54, 0.83, 0.46, 0.66, 0.58, 0.77, 0.5]

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: 7) {
                    if avatar > 0 {
                        Circle().fill(HomeSkeletonStyle.fill).frame(width: avatar, height: avatar)
                    } else if let leadingPill {
                        Capsule().fill(HomeSkeletonStyle.fill).frame(width: leadingPill, height: 5)
                    }
                    GeometryReader { proxy in
                        VStack(alignment: .leading, spacing: 4) {
                            HomeSkeletonBar(width: proxy.size.width * Self.widths[index % Self.widths.count], height: 9)
                            if avatar > 0 {
                                HomeSkeletonBar(width: proxy.size.width * 0.4, height: 7)
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: avatar > 0 ? 22 : 9)
                    HomeSkeletonBar(width: 24, height: 9)
                }
            }
        }
    }
}

/// A bar chart's columns, at heights that stay put between redraws.
struct HomeSkeletonColumns: View {
    var count: Int
    var width: CGFloat
    var height: CGFloat

    private static let ratios: [CGFloat] = [0.35, 0.62, 0.48, 0.86, 0.3, 0.71, 0.55, 0.94, 0.42, 0.68, 0.25, 0.8]

    var body: some View {
        // Dropped to whatever fits rather than squeezed: a column narrower
        // than the real chart's would misrepresent the shape that replaces it.
        GeometryReader { proxy in
            let fits = max(1, Int((proxy.size.width + 2) / (width + 2)))
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<min(count, fits), id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(HomeSkeletonStyle.fill)
                        .frame(width: width, height: max(3, height * Self.ratios[index % Self.ratios.count]))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: height, alignment: .bottom)
        }
        .frame(height: height)
    }
}

/// The rhythm chart's shape: additions above a baseline, deletions
/// mirrored below it, the way `RhythmChartContent` draws them.
struct HomeSkeletonMirroredColumns: View {
    var count: Int
    var width: CGFloat
    var height: CGFloat

    private static let up: [CGFloat] = [0.5, 0.86, 0.34, 0.68, 0.92, 0.44, 0.6, 0.28, 0.76, 0.52]
    private static let down: [CGFloat] = [0.3, 0.5, 0.18, 0.42, 0.62, 0.24, 0.36, 0.14, 0.46, 0.32]

    var body: some View {
        let half = height / 2
        GeometryReader { proxy in
            let fits = max(1, Int((proxy.size.width + 2) / (width + 2)))
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<min(count, fits), id: \.self) { index in
                    VStack(spacing: 1) {
                        Spacer(minLength: 0)
                        bar(half * Self.up[index % Self.up.count])
                        bar(half * Self.down[index % Self.down.count])
                        Spacer(minLength: 0)
                    }
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: height)
        }
        .frame(height: height)
    }

    private func bar(_ length: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(HomeSkeletonStyle.fill)
            .frame(width: width, height: max(2, length))
    }
}

/// The heatmap's cells — columns of rounded squares, clipped to whatever
/// width the card actually has.
struct HomeSkeletonDotGrid: View {
    var rows: Int
    var columns: Int
    var cell: CGFloat = 8
    var gap: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let fits = max(1, Int((proxy.size.width + gap) / (cell + gap)))
            HStack(alignment: .top, spacing: gap) {
                ForEach(0..<min(columns, fits), id: \.self) { _ in
                    VStack(spacing: gap) {
                        ForEach(0..<rows, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(HomeSkeletonStyle.fill)
                                .frame(width: cell, height: cell)
                        }
                    }
                }
            }
        }
        .frame(height: CGFloat(rows) * cell + CGFloat(rows - 1) * gap)
    }
}

struct HomeSkeletonDonut: View {
    var body: some View {
        Circle()
            .strokeBorder(HomeSkeletonStyle.fill, lineWidth: 12)
            .frame(width: 62, height: 62)
    }
}

/// The screenshot feed's tiles, in the same arrangement its content uses.
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
