import Foundation

/// One row of the rendered commit graph: a commit, the lane its dot sits in,
/// and every edge that has to be drawn inside that row's slice of canvas.
///
/// Segments are deliberately *self-contained per row*, so a row can be drawn
/// knowing nothing about its neighbours — which is what lets the view keep its
/// list lazy. Continuity across rows falls out of the geometry instead: every
/// edge leaves the bottom of a row vertically at a lane centre, and every edge
/// enters the next row the same way, so abutting rows join seamlessly.
public struct GitGraphRow: Sendable, Equatable, Identifiable {
    public let commit: GitCommit
    /// Column the dot sits in, counted from the left.
    public let lane: Int
    /// Palette slot for this commit's lane. Stable along a lane's whole run,
    /// so one branch keeps one colour from tip to merge base.
    public let colorIndex: Int
    public let segments: [GitGraphSegment]
    /// Lanes occupied by *this* row. The view takes the maximum across all
    /// rows for the gutter width: sizing the gutter per row makes every column
    /// to its right jitter as the graph widens and narrows.
    public let laneCount: Int

    public var id: String { commit.sha }

    public init(
        commit: GitCommit,
        lane: Int,
        colorIndex: Int,
        segments: [GitGraphSegment],
        laneCount: Int
    ) {
        self.commit = commit
        self.lane = lane
        self.colorIndex = colorIndex
        self.segments = segments
        self.laneCount = laneCount
    }
}

/// An edge inside one row.
///
/// The kinds are *geometric*, not semantic: they say only where the edge
/// starts and ends vertically, which is the sole thing the renderer needs.
/// What the edge means — a branch fanning out, a branch being absorbed, an
/// unrelated branch passing by — is carried by the lanes it joins. Encoding
/// meaning instead was the original bug: "a branch merging into an existing
/// lane" and "a lane converging onto this commit" are opposite geometries, and
/// sharing one case for both drew half the edges upside down.
public struct GitGraphSegment: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Top edge → bottom edge, in a lane this commit isn't on.
        case passThrough
        /// Top edge at `fromLane` → this row's dot.
        case incoming
        /// This row's dot → bottom edge at `toLane`.
        case outgoing
    }

    public let fromLane: Int
    public let toLane: Int
    public let colorIndex: Int
    public let kind: Kind

    public init(fromLane: Int, toLane: Int, colorIndex: Int, kind: Kind) {
        self.fromLane = fromLane
        self.toLane = toLane
        self.colorIndex = colorIndex
        self.kind = kind
    }

    /// True when the edge changes column and therefore has to be curved rather
    /// than drawn as a straight line.
    public var isDiagonal: Bool { fromLane != toLane }
}

public enum GitGraphLayout {
    /// Number of distinct palette slots `colorIndex` cycles through. The view's
    /// palette must have exactly this many entries, otherwise two lanes that
    /// were deliberately given different slots collapse to the same colour.
    public static let colorCount = 8

    /// Lays topologically ordered commits (newest first) out into lanes.
    ///
    /// Pure and total: unknown parents, multiple roots, and octopus merges all
    /// produce rows rather than throwing, because a 500-commit `--all` window
    /// routinely cuts the history off mid-branch and a truncated graph still
    /// has to draw.
    public static func rows(for commits: [GitCommit]) -> [GitGraphRow] {
        var lanes: [Lane?] = []
        var colorCursor = 0
        var rows: [GitGraphRow] = []
        rows.reserveCapacity(commits.count)

        /// Allocates a lane, preferring a free slot to the right of `origin` so
        /// branches fan outward from the commit that spawned them instead of
        /// darting back to column 0.
        func allocateLane(rightOf origin: Int) -> Int {
            if let index = lanes.indices.first(where: { $0 > origin && lanes[$0] == nil }) {
                return index
            }
            if let index = lanes.firstIndex(where: { $0 == nil }) { return index }
            lanes.append(nil)
            return lanes.count - 1
        }

        /// Hands out the next palette slot not already worn by a live lane, so
        /// two lanes drawn side by side never share a colour while both exist.
        func allocateColor() -> Int {
            let inUse = Set(lanes.compactMap { $0?.colorIndex })
            for offset in 0..<colorCount {
                let candidate = (colorCursor + offset) % colorCount
                if !inUse.contains(candidate) {
                    colorCursor = (candidate + 1) % colorCount
                    return candidate
                }
            }
            // Every slot is live — more concurrent branches than colours.
            let candidate = colorCursor % colorCount
            colorCursor = (candidate + 1) % colorCount
            return candidate
        }

        for commit in commits {
            let sha = commit.sha
            var segments: [GitGraphSegment] = []

            // 1. Place the commit. A lane already waiting for it means the
            //    child drawn above continued down into this row, so the dot
            //    needs a stub joining it to the top edge; a commit nobody is
            //    waiting for is a branch tip and gets a fresh lane and colour,
            //    with nothing drawn above the dot.
            let lane: Int
            let colorIndex: Int
            if let existing = lanes.firstIndex(where: { $0?.expected == sha }) {
                lane = existing
                colorIndex = lanes[existing]!.colorIndex
                segments.append(GitGraphSegment(
                    fromLane: lane, toLane: lane, colorIndex: colorIndex, kind: .incoming
                ))
            } else {
                lane = allocateLane(rightOf: -1)
                colorIndex = allocateColor()
            }

            // 2. Any *other* lane waiting for this commit converges into the
            //    dot and ends here — this is a branch being caught up with.
            for index in lanes.indices where index != lane && lanes[index]?.expected == sha {
                segments.append(GitGraphSegment(
                    fromLane: index, toLane: lane, colorIndex: lanes[index]!.colorIndex, kind: .incoming
                ))
                lanes[index] = nil
            }
            lanes[lane] = nil

            // 3. Lanes with nothing to do with this commit run straight past.
            for index in lanes.indices where index != lane {
                guard let occupant = lanes[index] else { continue }
                segments.append(GitGraphSegment(
                    fromLane: index, toLane: index, colorIndex: occupant.colorIndex, kind: .passThrough
                ))
            }

            // 4. Descend to the parents. The first parent inherits the lane and
            //    its colour so mainline history stays one unbroken column; the
            //    rest fan out. A parent another lane is already waiting for
            //    needs no new lane — the edge just curves across into it, which
            //    is what draws a branch rejoining its base.
            for (offset, parent) in commit.parents.enumerated() {
                if let existing = lanes.firstIndex(where: { $0?.expected == parent }) {
                    segments.append(GitGraphSegment(
                        fromLane: lane, toLane: existing, colorIndex: lanes[existing]!.colorIndex, kind: .outgoing
                    ))
                } else if offset == 0 {
                    lanes[lane] = Lane(expected: parent, colorIndex: colorIndex)
                    segments.append(GitGraphSegment(
                        fromLane: lane, toLane: lane, colorIndex: colorIndex, kind: .outgoing
                    ))
                } else {
                    let branchLane = allocateLane(rightOf: lane)
                    let branchColor = allocateColor()
                    lanes[branchLane] = Lane(expected: parent, colorIndex: branchColor)
                    segments.append(GitGraphSegment(
                        fromLane: lane, toLane: branchLane, colorIndex: branchColor, kind: .outgoing
                    ))
                }
            }

            // Trailing empties are dropped so the graph narrows again after a
            // branch closes. Only the tail is trimmed: compacting interior gaps
            // would shift live lanes sideways mid-run, and a lane that changes
            // column between two rows tears the line drawn through it.
            while lanes.last == .some(nil) { lanes.removeLast() }

            let widest = segments.reduce(max(lane, lanes.count - 1)) {
                max($0, max($1.fromLane, $1.toLane))
            }
            rows.append(GitGraphRow(
                commit: commit,
                lane: lane,
                colorIndex: colorIndex,
                segments: segments,
                laneCount: max(1, widest + 1)
            ))
        }

        return rows
    }

    /// Widest point of the graph — the gutter width the view has to reserve.
    public static func laneCount(of rows: [GitGraphRow]) -> Int {
        max(1, rows.map(\.laneCount).max() ?? 1)
    }

    /// A lane in flight: the SHA it is descending towards, and the colour it
    /// keeps until it gets there.
    private struct Lane: Equatable {
        var expected: String
        var colorIndex: Int
    }
}
