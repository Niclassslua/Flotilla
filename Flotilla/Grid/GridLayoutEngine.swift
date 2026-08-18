import SwiftUI
import SessionKit
import SettingsKit

/// How big a tile wants to be — the grid's single layout knob.
///
/// Density and an explicit column count were two ways of saying the same
/// thing, and keeping both meant two controls to reason about and a menu to
/// open. One scale replaces them: the column count is a *result* of tile size,
/// so widening the window grows tiles and only opens a new column once a whole
/// one fits.
///
/// Stored as the tile's preferred width in `gridMinimumTileWidth`, which is the
/// value that setting has always held.
struct GridZoom: Equatable, Sendable {
    /// Preferred tile width. The realised width is usually larger, since the
    /// columns share out whatever the window has left over.
    var tileWidth: CGFloat

    /// Coarse enough that one step is always a visible change, fine enough
    /// that stepping to a specific column count is quick.
    static let steps: [CGFloat] = [260, 300, 350, 410, 480, 560, 660, 780]

    static let `default` = GridZoom(tileWidth: 410)

    init(tileWidth: CGFloat) {
        self.tileWidth = min(max(tileWidth, Self.steps.first!), Self.steps.last!)
    }

    init(setting: Double) {
        self.init(tileWidth: CGFloat(setting))
    }

    var setting: Double { Double(tileWidth) }

    /// Tiles shrink to fill the window until they hit this height, then the
    /// grid scrolls rather than shrinking further. Tied to width so a tile
    /// keeps a sane shape at every zoom level: the previous grid divided the
    /// viewport height by the row count unconditionally, so eight sessions
    /// produced ~100pt tiles with almost no room for the terminal.
    var minimumTileHeight: CGFloat {
        min(max(tileWidth * 0.62, 180), 460)
    }

    var canZoomIn: Bool { tileWidth < Self.steps.last! }
    var canZoomOut: Bool { tileWidth > Self.steps.first! }

    /// Bigger tiles, fewer of them.
    func zoomedIn() -> GridZoom {
        GridZoom(tileWidth: Self.steps.first { $0 > tileWidth } ?? tileWidth)
    }

    /// Smaller tiles, more of them.
    func zoomedOut() -> GridZoom {
        GridZoom(tileWidth: Self.steps.last { $0 < tileWidth } ?? tileWidth)
    }

    /// Continuous zoom, for pinch and Command-scroll. Snaps to the nearest
    /// step so the discrete controls and the gestures stay in agreement.
    func scaled(by factor: CGFloat) -> GridZoom {
        let target = tileWidth * factor
        let nearest = Self.steps.min { abs($0 - target) < abs($1 - target) } ?? tileWidth
        return GridZoom(tileWidth: nearest)
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

/// Solves column count and tile height for a container, implementing
/// fit-then-scroll: fill the window while tiles stay readable, then scroll.
func resolveGridLayout(
    containerSize: CGSize,
    sessionCount: Int,
    zoom: GridZoom
) -> ResolvedGridLayout {
    guard sessionCount > 0 else {
        return ResolvedGridLayout(columnCount: 1, tileHeight: zoom.minimumTileHeight)
    }

    let gutter = GridLayoutMetrics.gutter
    let availableWidth = max(1, containerSize.width - GridLayoutMetrics.padding * 2)
    let availableHeight = max(1, containerSize.height - GridLayoutMetrics.padding * 2)

    // Clamping to `sessionCount` keeps two sessions from sitting in four skinny
    // columns; this behaviour is carried over from the previous grid.
    let fitting = Int((availableWidth + gutter) / (zoom.tileWidth + gutter))
    let columnCount = min(max(1, fitting), sessionCount)

    let rowCount = Int(ceil(Double(sessionCount) / Double(columnCount)))
    let idealHeight = (availableHeight - CGFloat(rowCount - 1) * gutter) / CGFloat(rowCount)

    // Fit-then-scroll: tiles shrink to fill the viewport until they reach the
    // zoom level's floor, past which the enclosing ScrollView takes over.
    return ResolvedGridLayout(
        columnCount: columnCount,
        tileHeight: max(idealHeight, zoom.minimumTileHeight)
    )
}

// MARK: - Session ordering

extension Array where Element == Session {
    /// Applies the user's saved drag order, keeping any session the order does
    /// not mention (newly created ones) at the end in their existing order.
    func ordered(by savedOrder: [String]) -> [Session] {
        guard !savedOrder.isEmpty else { return self }
        let rank = Dictionary(
            uniqueKeysWithValues: savedOrder.enumerated().map { ($0.element, $0.offset) }
        )
        return enumerated()
            .sorted { lhs, rhs in
                let lhsRank = rank[lhs.element.id.uuidString] ?? Int.max
                let rhsRank = rank[rhs.element.id.uuidString] ?? Int.max
                // Fall back to the original index so the sort stays stable for
                // sessions that share a rank (i.e. both unranked).
                return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
            }
            .map(\.element)
    }
}
