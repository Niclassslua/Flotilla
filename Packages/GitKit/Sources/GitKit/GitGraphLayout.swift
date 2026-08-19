import Foundation

public struct GitGraphRow: Sendable, Equatable {
    public let commit: GitCommit
    public let lane: Int              // which column the dot sits in
    public let colorIndex: Int        // stable per-lane color
    public let segments: [GitGraphSegment]  // edges drawn within THIS row
    public let laneCount: Int

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

public struct GitGraphSegment: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case passThrough
        case branchOut
        case mergeIn
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
}

public enum GitGraphLayout {
    /// Pure function converting a list of topo-ordered commits into graph rows.
    /// Each row contains the commit, its dot position (lane), color, laneCount,
    /// and self-contained segments for edge rendering within that row.
    public static func rows(for commits: [GitCommit]) -> [GitGraphRow] {
        var activeLanes: [String?] = [] // index -> SHA expected in that lane
        var rows: [GitGraphRow] = []
        rows.reserveCapacity(commits.count)

        for commit in commits {
            let sha = commit.sha

            // 1. Find or assign a lane for this commit
            let lane: Int
            if let existingIndex = activeLanes.firstIndex(where: { $0 == sha }) {
                lane = existingIndex
            } else if let freeIndex = activeLanes.firstIndex(where: { $0 == nil }) {
                lane = freeIndex
            } else {
                lane = activeLanes.count
                activeLanes.append(nil)
            }

            var segments: [GitGraphSegment] = []

            // If other lanes were also expecting this commit (convergence/merge from above),
            // record incoming mergeIn segments from those lanes to our lane
            for (idx, expected) in activeLanes.enumerated() where idx != lane && expected == sha {
                segments.append(GitGraphSegment(
                    fromLane: idx,
                    toLane: lane,
                    colorIndex: idx,
                    kind: .mergeIn
                ))
                activeLanes[idx] = nil
            }

            // Clear expectations for this commit
            activeLanes[lane] = nil

            // 2. Pass-through for other active lanes that are not this commit
            for (idx, expected) in activeLanes.enumerated() where idx != lane && expected != nil {
                segments.append(GitGraphSegment(
                    fromLane: idx,
                    toLane: idx,
                    colorIndex: idx,
                    kind: .passThrough
                ))
            }

            // 3. Connect this commit to its parents
            let parents = commit.parents

            if parents.isEmpty {
                // Root commit — lane ends here, no downward edge from this lane
            } else if parents.count == 1 {
                let parentSHA = parents[0]
                if let targetLane = activeLanes.firstIndex(where: { $0 == parentSHA }) {
                    // Parent is already expected in another lane -> merge into it
                    segments.append(GitGraphSegment(
                        fromLane: lane,
                        toLane: targetLane,
                        colorIndex: lane,
                        kind: .mergeIn
                    ))
                } else {
                    // Continue this lane with the parent
                    activeLanes[lane] = parentSHA
                    segments.append(GitGraphSegment(
                        fromLane: lane,
                        toLane: lane,
                        colorIndex: lane,
                        kind: .passThrough
                    ))
                }
            } else {
                // Merge commit (2+ parents)
                // First parent continues in current lane or merges into existing
                let firstParent = parents[0]
                if let targetLane = activeLanes.firstIndex(where: { $0 == firstParent }) {
                    segments.append(GitGraphSegment(
                        fromLane: lane,
                        toLane: targetLane,
                        colorIndex: lane,
                        kind: .mergeIn
                    ))
                } else {
                    activeLanes[lane] = firstParent
                    segments.append(GitGraphSegment(
                        fromLane: lane,
                        toLane: lane,
                        colorIndex: lane,
                        kind: .passThrough
                    ))
                }

                // Additional parents branch out or merge in
                for parentSHA in parents.dropFirst() {
                    if let targetLane = activeLanes.firstIndex(where: { $0 == parentSHA }) {
                        segments.append(GitGraphSegment(
                            fromLane: lane,
                            toLane: targetLane,
                            colorIndex: targetLane,
                            kind: .mergeIn
                        ))
                    } else {
                        // Allocate a new or free lane for this parent
                        let branchLane: Int
                        if let freeIndex = activeLanes.firstIndex(where: { $0 == nil }) {
                            branchLane = freeIndex
                        } else {
                            branchLane = activeLanes.count
                            activeLanes.append(nil)
                        }
                        activeLanes[branchLane] = parentSHA
                        segments.append(GitGraphSegment(
                            fromLane: lane,
                            toLane: branchLane,
                            colorIndex: branchLane,
                            kind: .branchOut
                        ))
                    }
                }
            }

            // Compact trailing nil lanes in activeLanes
            while let last = activeLanes.last, last == nil {
                activeLanes.removeLast()
            }

            let maxLane = max(
                lane,
                activeLanes.count - 1,
                segments.map { max($0.fromLane, $0.toLane) }.max() ?? 0
            )
            let laneCount = max(1, maxLane + 1)

            rows.append(GitGraphRow(
                commit: commit,
                lane: lane,
                colorIndex: lane,
                segments: segments,
                laneCount: laneCount
            ))
        }

        return rows
    }
}
