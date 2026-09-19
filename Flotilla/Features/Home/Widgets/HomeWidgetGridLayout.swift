import SwiftUI
import DesignSystem

/// Carries each subview's grid span into `HomeWidgetGridLayout`, which reads
/// it back out during placement — the standard `Layout` pattern for passing
/// per-child data down without a matching argument list.
struct HomeWidgetSpanKey: LayoutValueKey {
    static let defaultValue: (columns: Int, rows: Int) = (1, 1)
}

extension View {
    /// Declares a subview's grid footprint for `HomeWidgetGridLayout`.
    /// `columns` of `Int.max` means "fill the row" (a `wide` widget); the
    /// layout resolves it once it knows the actual column count.
    func homeWidgetSpan(columns: Int, rows: Int) -> some View {
        layoutValue(key: HomeWidgetSpanKey.self, value: (columns, rows))
    }
}

/// Lays widgets out on the dense-packed grid `HomeWidgetPacker` computes.
/// Column count is derived from the available width; row height is fixed so
/// the grid never needs to know a widget's content to lay it out.
struct HomeWidgetGridLayout: Layout {
    static let minColumnWidth: CGFloat = 160
    static let maxColumnWidth: CGFloat = 220
    static let minColumns = 2
    static let maxColumns = 6
    static let rowHeight: CGFloat = 170
    static let gap: CGFloat = FlotillaSpacing.large

    static func columnCount(for width: CGFloat) -> Int {
        guard width > 0 else { return minColumns }
        let fitted = Int((width + gap) / (minColumnWidth + gap))
        return min(max(fitted, minColumns), maxColumns)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? Self.minColumnWidth * CGFloat(Self.minColumns)
        let columns = Self.columnCount(for: width)
        let rects = packedRects(subviews: subviews, columns: columns)
        let maxRow = rects.map { $0.row + $0.rowSpan }.max() ?? 0
        let height = maxRow > 0 ? CGFloat(maxRow) * Self.rowHeight + CGFloat(maxRow - 1) * Self.gap : 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = Self.columnCount(for: bounds.width)
        let columnWidth = min((bounds.width - CGFloat(columns - 1) * Self.gap) / CGFloat(columns), Self.maxColumnWidth)
        // Centered when the capped column width leaves the row narrower than
        // the bounds it was proposed — a wide window with only 2 columns.
        let gridWidth = columnWidth * CGFloat(columns) + Self.gap * CGFloat(columns - 1)
        let originX = bounds.minX + max(0, (bounds.width - gridWidth) / 2)
        let rects = packedRects(subviews: subviews, columns: columns)

        for (index, subview) in subviews.enumerated() {
            guard let rect = rects[safe: index] else { continue }
            let x = originX + CGFloat(rect.column) * (columnWidth + Self.gap)
            let y = bounds.minY + CGFloat(rect.row) * (Self.rowHeight + Self.gap)
            let width = CGFloat(rect.columnSpan) * columnWidth + CGFloat(rect.columnSpan - 1) * Self.gap
            let height = CGFloat(rect.rowSpan) * Self.rowHeight + CGFloat(rect.rowSpan - 1) * Self.gap
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: width, height: height)
            )
        }
    }

    /// Packs by subview index — `HomeWidgetGrid` is expected to hand
    /// subviews in the same order as its entry list, so index order is the
    /// packer's placement order.
    private func packedRects(subviews: Subviews, columns: Int) -> [HomeWidgetRect] {
        let items = subviews.enumerated().map { index, subview -> HomeWidgetPacker.Item<Int> in
            let span = subview[HomeWidgetSpanKey.self]
            let columnSpan = span.columns == Int.max ? columns : span.columns
            return HomeWidgetPacker.Item(id: index, columnSpan: columnSpan, rowSpan: span.rows)
        }
        let packed = HomeWidgetPacker.pack(items, columns: columns)
        return subviews.indices.map { packed[$0] ?? HomeWidgetRect(column: 0, row: 0, columnSpan: 1, rowSpan: 1) }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
