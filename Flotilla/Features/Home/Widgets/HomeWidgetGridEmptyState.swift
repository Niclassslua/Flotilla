import SwiftUI
import SettingsKit
import DesignSystem

/// The widget grid with nothing in it. Instead of an illustration it shows
/// the real thing: a row of live widgets rendered inert and knocked back,
/// sitting in the same dashed cells the grid draws while editing. The cells
/// brighten under the pointer, so an area that is otherwise empty still
/// answers to the cursor and reads as somewhere things go.
struct HomeWidgetGridEmptyState: View {
    @Bindable var store: AppStore
    @Bindable var insights: HomeInsights
    let geometry: HomeWidgetGridGeometry
    let onAdd: () -> Void

    /// The pointer in this view's coordinate space, driving the cell glow.
    @State private var pointer: CGPoint?

    /// The widgets the ghost row shows, in order. All three read commit
    /// activity, so an empty Home costs one fetch however wide the grid is —
    /// and all three are `.small`, so each lands in exactly one cell.
    static let ghostKinds: [HomeWidgetKind] = [.streak, .today, .agentShare]

    /// What `HomeInsights` must have loaded for the ghost row to show real
    /// numbers; the grid unions this in while the layout is empty.
    static var dataNeeds: Set<HomeDataNeed> { Set(ghostKinds.flatMap(\.dataNeeds)) }

    private static let space = "HomeWidgetGridEmptyState"
    /// How far from a cell's center the pointer still lights it up.
    private static let glowReach: CGFloat = 1.5
    private static let dash = StrokeStyle(lineWidth: 1, dash: [4, 4])

    private var ghosts: [HomeWidgetKind] { Array(Self.ghostKinds.prefix(geometry.columns)) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            cells
            ghostRow
            callToAction
        }
        .frame(maxWidth: .infinity, minHeight: geometry.cell, maxHeight: geometry.cell, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
            switch phase {
            case .active(let location): pointer = location
            case .ended: pointer = nil
            }
        }
        // Only the pointer arriving and leaving animates; while it moves the
        // glow tracks it directly, which is already as smooth as the cursor.
        .animation(FlotillaMotion.normal.curve, value: pointer == nil)
        .accessibilityIdentifier(AXID.homeWidgetEmptyState.rawValue)
    }

    // MARK: - Cells

    /// One dashed cell per column, lit by how close the pointer is.
    private var cells: some View {
        ForEach(0..<geometry.columns, id: \.self) { column in
            let frame = geometry.frame(for: HomeWidgetRect(column: column, row: 0, columnSpan: 1, rowSpan: 1))
            let glow = glow(for: frame)
            HomeWidgetCardMetrics.shape
                .fill(FlotillaColors.accent.opacity(0.10 * glow))
                .overlay {
                    HomeWidgetCardMetrics.shape
                        .strokeBorder(FlotillaColors.textPrimary.opacity(0.1), style: Self.dash)
                    HomeWidgetCardMetrics.shape
                        .strokeBorder(FlotillaColors.accent.opacity(0.6 * glow), style: Self.dash)
                }
                .opacity(0.5 + 0.5 * glow)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
        }
        .allowsHitTesting(false)
    }

    /// 1 at the pointer, falling off to 0 `glowReach` cells away.
    private func glow(for frame: CGRect) -> CGFloat {
        guard let pointer else { return 0 }
        let distance = hypot(pointer.x - frame.midX, pointer.y - frame.midY)
        return max(0, 1 - distance / (geometry.cell * Self.glowReach))
    }

    // MARK: - Ghosts

    /// Real widgets with the user's real data, rendered inert and dimmed —
    /// a preview of what lands here, not a drawing of one.
    private var ghostRow: some View {
        let frames = geometry.frames(for: ghosts.map { (id: $0, size: HomeWidgetSize.small, kind: Optional($0)) })
        return ForEach(ghosts) { kind in
            if let frame = frames[kind] {
                HomeWidgetView(
                    entry: HomeWidgetEntry(kind: kind.rawValue, size: HomeWidgetSize.small.rawValue),
                    size: .small,
                    store: store,
                    insights: insights,
                    isPreview: true
                )
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
            }
        }
        .saturation(0.4)
        .opacity(0.32)
        .allowsHitTesting(false)
        // The ghosts carry each widget's own identifier; leaving them visible
        // to accessibility would announce widgets that aren't placed.
        .accessibilityHidden(true)
    }

    // MARK: - Call to action

    private var callToAction: some View {
        VStack(spacing: FlotillaSpacing.small) {
            Button(action: onAdd) {
                Label("Add Widgets", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(FlotillaColors.accent)
            .controlSize(.large)
            .accessibilityIdentifier(AXID.homeWidgetEmptyAddButton.rawValue)
            Text("Your activity, your layout — ⌘E to arrange.")
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textSecondary)
        }
        // A plate behind the call to action: it sits over the ghost row, and
        // dim widget content behind live text is still content behind text.
        .padding(.horizontal, FlotillaSpacing.xLarge)
        .padding(.vertical, FlotillaSpacing.large)
        .background {
            RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous)
                .fill(FlotillaColors.surfaceElevated.opacity(0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous)
                        .strokeBorder(FlotillaColors.textPrimary.opacity(0.08), lineWidth: FlotillaBorderWidth.thin)
                )
                .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
