import SwiftUI
import DesignSystem
import SettingsKit

/// The grid's geometry for one width: how many columns fit, how big a cell
/// is, and where every widget lands. Pure value math — the grid view, the
/// drag-to-move gesture and the resize handle all read the same frames from
/// here, so what you drag against is exactly what's drawn.
///
/// Cells are square, like macOS widgets: a small widget is the same size
/// everywhere, a medium is two of them side by side, a large is a 2×2 block.
struct HomeWidgetGridGeometry: Equatable {
    static let minColumnWidth: CGFloat = 160
    static let maxColumnWidth: CGFloat = 220
    static let minColumns = 2
    static let maxColumns = 6
    static let gap: CGFloat = FlotillaSpacing.large

    let columns: Int
    let cell: CGFloat
    /// Leading inset that centers the grid when capped cells leave spare width.
    let originX: CGFloat

    init(width: CGFloat) {
        let gap = Self.gap
        let fitted = Int((max(width, 0) + gap) / (Self.minColumnWidth + gap))
        let columns = min(max(fitted, Self.minColumns), Self.maxColumns)
        let cell = min((width - CGFloat(columns - 1) * gap) / CGFloat(columns), Self.maxColumnWidth)
        self.columns = columns
        self.cell = max(cell, 1)
        let gridWidth = self.cell * CGFloat(columns) + gap * CGFloat(columns - 1)
        self.originX = max(0, (width - gridWidth) / 2)
    }

    /// Column span for a size at this column count — `wide` fills the row,
    /// everything else is clamped so a 2-wide widget still fits 2 columns.
    func columnSpan(for size: HomeWidgetSize) -> Int {
        size == .wide ? columns : min(size.columnSpan, columns)
    }

    func frame(for rect: HomeWidgetRect) -> CGRect {
        CGRect(
            x: originX + CGFloat(rect.column) * (cell + Self.gap),
            y: CGFloat(rect.row) * (cell + Self.gap),
            width: CGFloat(rect.columnSpan) * cell + CGFloat(rect.columnSpan - 1) * Self.gap,
            height: CGFloat(rect.rowSpan) * cell + CGFloat(rect.rowSpan - 1) * Self.gap
        )
    }

    /// Frames for `items` in order, keyed by id.
    func frames<ID: Hashable>(for items: [(id: ID, size: HomeWidgetSize)]) -> [ID: CGRect] {
        let packed = HomeWidgetPacker.pack(
            items.map { HomeWidgetPacker.Item(id: $0.id, columnSpan: columnSpan(for: $0.size), rowSpan: $0.size.rowSpan) },
            columns: columns
        )
        return packed.mapValues(frame(for:))
    }

    func height<ID: Hashable>(of frames: [ID: CGRect]) -> CGFloat {
        frames.values.map(\.maxY).max() ?? 0
    }

    /// The supported size whose footprint is closest to `target` (a width and
    /// height in points) — what the corner handle snaps to while dragging.
    func nearestSize(to target: CGSize, among supported: [HomeWidgetSize]) -> HomeWidgetSize? {
        let pitch = cell + Self.gap
        let wantColumns = (target.width + Self.gap) / pitch
        let wantRows = (target.height + Self.gap) / pitch
        return supported.min { lhs, rhs in
            distance(lhs, wantColumns, wantRows) < distance(rhs, wantColumns, wantRows)
        }
    }

    private func distance(_ size: HomeWidgetSize, _ columns: CGFloat, _ rows: CGFloat) -> CGFloat {
        abs(CGFloat(columnSpan(for: size)) - columns) + abs(CGFloat(size.rowSpan) - rows)
    }
}

extension HomeWidgetGridGeometry {
    /// What a drag to `pointer` should do to the order. The dragged widget
    /// takes the slot of whichever widget is under the pointer; below every
    /// widget, it moves to the end.
    ///
    /// `lastSwap` is the widget it last swapped with: the reflow slides that
    /// widget away, often to right under the pointer again, and swapping back
    /// immediately would make the two oscillate — so a swap with the same
    /// target waits until the pointer has left it once.
    ///
    /// Returns the index to move to (`nil`: leave the order alone) and the
    /// `lastSwap` to remember.
    static func moveTarget(
        pointer: CGPoint,
        dragged: UUID,
        order: [UUID],
        frames: [UUID: CGRect],
        lastSwap: UUID?
    ) -> (index: Int?, lastSwap: UUID?) {
        if let target = order.first(where: { $0 != dragged && frames[$0]?.contains(pointer) == true }) {
            guard target != lastSwap, let index = order.firstIndex(of: target) else { return (nil, lastSwap) }
            return (index, target)
        }
        let bottom = frames.values.map(\.maxY).max() ?? 0
        if pointer.y > bottom, order.last != dragged {
            return (order.count, nil)
        }
        return (nil, nil)
    }
}
