import Foundation

/// A widget's position on the grid, in cell units.
struct HomeWidgetRect: Equatable, Sendable {
    var column: Int
    var row: Int
    var columnSpan: Int
    var rowSpan: Int
}

/// Packs widgets onto the grid: dense first-fit, left-to-right, top-to-bottom,
/// filling holes a large widget leaves behind — the same algorithm CSS calls
/// `grid-auto-flow: dense`. Pure and stateless so it's cheap to call on every
/// layout change and to test exhaustively.
enum HomeWidgetPacker {
    /// One entry to place, keyed by whatever the caller uses to identify it.
    struct Item<ID: Hashable> {
        let id: ID
        /// Column span before `wide` resolution; `wide` widgets pass
        /// `columns` here so they always fill the row.
        let columnSpan: Int
        let rowSpan: Int

        init(id: ID, columnSpan: Int, rowSpan: Int) {
            self.columnSpan = columnSpan
            self.rowSpan = rowSpan
            self.id = id
        }
    }

    /// Packs `items` in order into a grid of `columns` columns. A `wide`
    /// item's span should already be resolved to `columns` by the caller
    /// (`HomeWidgetKind`/`HomeWidgetSize` don't know the column count).
    static func pack<ID: Hashable>(_ items: [Item<ID>], columns: Int) -> [ID: HomeWidgetRect] {
        guard columns > 0 else { return [:] }
        var occupied: Set<Int> = [] // row*columns + column, for cells taken
        var result: [ID: HomeWidgetRect] = [:]
        var maxRow = 0

        func fits(column: Int, row: Int, columnSpan: Int, rowSpan: Int) -> Bool {
            guard column + columnSpan <= columns else { return false }
            for r in row..<(row + rowSpan) {
                for c in column..<(column + columnSpan) {
                    if occupied.contains(r * columns + c) { return false }
                }
            }
            return true
        }

        func occupy(column: Int, row: Int, columnSpan: Int, rowSpan: Int) {
            for r in row..<(row + rowSpan) {
                for c in column..<(column + columnSpan) {
                    occupied.insert(r * columns + c)
                }
            }
            maxRow = max(maxRow, row + rowSpan)
        }

        for item in items {
            let columnSpan = min(item.columnSpan, columns)
            let rowSpan = max(item.rowSpan, 1)
            // Dense fill: scan from the very top-left every time, not from
            // where the previous item landed, so a later small widget can
            // fill a hole an earlier large one left behind.
            var placed = false
            var row = 0
            searching: while !placed {
                for column in 0...(columns - columnSpan) {
                    if fits(column: column, row: row, columnSpan: columnSpan, rowSpan: rowSpan) {
                        occupy(column: column, row: row, columnSpan: columnSpan, rowSpan: rowSpan)
                        result[item.id] = HomeWidgetRect(column: column, row: row, columnSpan: columnSpan, rowSpan: rowSpan)
                        placed = true
                        break searching
                    }
                }
                row += 1
            }
        }
        return result
    }

    /// Where a dragged widget would land among `frames` (each already-packed
    /// rect, keyed by the same order as the caller's entry list) if dropped
    /// at `point`. Returns an insertion index into that ordered list — the
    /// nearest frame's index, or the count if `point` is past the last one.
    static func insertionIndex(for point: CGPoint, orderedFrames: [CGRect]) -> Int {
        guard !orderedFrames.isEmpty else { return 0 }
        // Frames sharing `point`'s row band, in their original (left-to-right)
        // order — several frames can have the same y-range, so the row match
        // alone doesn't tell us where in x order the point falls.
        let rowIndices = orderedFrames.indices.filter { point.y >= orderedFrames[$0].minY && point.y <= orderedFrames[$0].maxY }
        if !rowIndices.isEmpty {
            for index in rowIndices {
                if point.x < orderedFrames[index].midX { return index }
            }
            return rowIndices.last! + 1
        }
        // No frame's row contains this y: insert before the first frame
        // entirely below it, or at the end if we're past everything.
        if let below = orderedFrames.firstIndex(where: { point.y < $0.minY }) { return below }
        return orderedFrames.count
    }
}
