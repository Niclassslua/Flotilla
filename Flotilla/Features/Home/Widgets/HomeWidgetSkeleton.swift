import SwiftUI
import DesignSystem

/// Placeholder while a Home widget's data is still loading.
///
/// One shared pulse chrome for every kind — layout-stable per-kind skeletons
/// were dropped as maintenance cost that didn't pay for itself.
struct HomeWidgetSkeleton: View {
    let kind: HomeWidgetKind
    let size: HomeWidgetSize

    var body: some View {
        HomeSkeletonPulse {
            VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
                HomeSkeletonBlock(width: titleWidth, height: 12)
                ForEach(0..<rowCount, id: \.self) { index in
                    GeometryReader { proxy in
                        HomeSkeletonBlock(
                            width: proxy.size.width * HomeSkeletonRatio.title(index),
                            height: rowHeight
                        )
                    }
                    .frame(height: rowHeight)
                }
                Spacer(minLength: 0)
            }
            .padding(FlotillaSpacing.medium)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading \(kind.title)")
        .accessibilityIdentifier(AXID.homeWidgetSkeleton.rawValue + kind.rawValue)
    }

    private var titleWidth: CGFloat {
        switch size {
        case .small: 72
        case .medium, .wide: 120
        case .large: 160
        }
    }

    private var rowCount: Int {
        switch size {
        case .small: 2
        case .medium, .wide: 3
        case .large: 6
        }
    }

    private var rowHeight: CGFloat {
        size == .small ? 10 : 14
    }
}

// MARK: - Pulse

enum HomeSkeletonStyle {
    /// Placeholder shapes are drawn **opaque** and dimmed by `HomeSkeletonPulse`.
    static let fill = FlotillaColors.textPrimary
    static let dim: Double = 0.10
    static let bright: Double = 0.24
    static let resting: Double = 0.16
    static let highlight = FlotillaColors.textPrimary.opacity(0.3)
    static let period: Double = 1.5
}

/// Classic loading pulse used by Home widgets and IssuePicker.
struct HomeSkeletonPulse<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            content.opacity(HomeSkeletonStyle.resting)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: HomeSkeletonStyle.period)
                    / HomeSkeletonStyle.period
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

enum HomeSkeletonRatio {
    private static let titles: [CGFloat] = [0.74, 0.52, 0.86, 0.45, 0.67, 0.58, 0.79, 0.49, 0.71, 0.55, 0.83, 0.47, 0.63]
    private static let subtitles: [CGFloat] = [0.45, 0.62, 0.38, 0.55, 0.48, 0.66, 0.41, 0.58, 0.5, 0.35, 0.6, 0.43, 0.52]

    static func title(_ index: Int) -> CGFloat { titles[index % titles.count] }
    static func subtitle(_ index: Int) -> CGFloat { subtitles[index % subtitles.count] }
}

// MARK: - Primitives

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
