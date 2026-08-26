import SwiftUI
import SettingsKit

/// The grid's layout knob: how many columns to show, and how many rows fit
/// the viewport before it scrolls.
///
/// Set from the toolbar's grid-size picker — a drag/click swatch modeled on
/// the "insert table" grids in Office apps, rather than a continuous zoom
/// slider. Columns are a hard count (not derived from window width), and
/// rows sets how tall each tile gets: taller for fewer rows, shorter for
/// more, always clamped so a tile stays legible. Sessions beyond
/// `columns * rows` simply wrap into further rows and scroll, same as before.
struct GridDimensions: Equatable, Sendable {
    var columns: Int
    var rows: Int

    static let columnRange = 1...4
    static let rowRange = 1...4

    static let `default` = GridDimensions(columns: 3, rows: 2)

    init(columns: Int, rows: Int) {
        self.columns = min(max(columns, Self.columnRange.lowerBound), Self.columnRange.upperBound)
        self.rows = min(max(rows, Self.rowRange.lowerBound), Self.rowRange.upperBound)
    }

    init(columnSetting: Int, rowSetting: Int) {
        self.init(columns: columnSetting, rows: rowSetting)
    }

    /// "columns×rows", matching the picker's own label under the swatch.
    var label: String { "\(columns)×\(rows)" }

    /// The most sessions the grid will render at once. Selecting more
    /// sessions than this doesn't grow the grid — it queues them, visible
    /// again once the picker is widened.
    var capacity: Int { columns * rows }

    /// A tile never shrinks below this, however many rows are requested —
    /// the previous grid divided viewport height by row count unconditionally,
    /// so a tall row count produced tiles with almost no room for the terminal.
    static let minimumTileHeight: CGFloat = 180

    var canZoomIn: Bool { columns > Self.columnRange.lowerBound }
    var canZoomOut: Bool { columns < Self.columnRange.upperBound }

    /// Bigger tiles, fewer columns.
    func zoomedIn() -> GridDimensions {
        GridDimensions(columns: columns - 1, rows: rows)
    }

    /// Smaller tiles, more columns.
    func zoomedOut() -> GridDimensions {
        GridDimensions(columns: columns + 1, rows: rows)
    }
}

struct ResolvedGridLayout: Equatable {
    let columnCount: Int
    let tileHeight: CGFloat

    var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 1), spacing: GridLayoutMetrics.gutter),
            count: columnCount
        )
    }
}

enum GridLayoutMetrics {
    static let gutter: CGFloat = 12
    static let padding: CGFloat = 12
}

/// Solves column count and tile height for a container: columns come
/// straight from the picker, tile height fits exactly `dimensions.rows` rows
/// into the viewport before the grid scrolls for the rest.
func resolveGridLayout(
    containerSize: CGSize,
    sessionCount: Int,
    dimensions: GridDimensions
) -> ResolvedGridLayout {
    guard sessionCount > 0 else {
        return ResolvedGridLayout(columnCount: dimensions.columns, tileHeight: GridDimensions.minimumTileHeight)
    }

    let gutter = GridLayoutMetrics.gutter
    let availableHeight = max(1, containerSize.height - GridLayoutMetrics.padding * 2)

    // Clamping to `sessionCount` keeps two sessions from sitting in four skinny
    // columns; this behaviour is carried over from the previous grid.
    let columnCount = min(max(1, dimensions.columns), sessionCount)

    // Size rows to how many are actually needed for `sessionCount`, not to
    // the picker's row setting — otherwise two sessions in a 3×2 grid would
    // sit in a single half-height row, leaving the bottom of the screen
    // empty. Only once sessions overflow the picker's row count does that
    // setting take over, at which point the extra rows scroll as before.
    let neededRows = Int((Double(sessionCount) / Double(columnCount)).rounded(.up))
    let rowCount = min(max(1, dimensions.rows), max(1, neededRows))
    let idealHeight = (availableHeight - CGFloat(rowCount - 1) * gutter) / CGFloat(rowCount)

    return ResolvedGridLayout(
        columnCount: columnCount,
        tileHeight: max(idealHeight, GridDimensions.minimumTileHeight)
    )
}
