import Foundation

/// How long a session has been alive, in the single-unit shorthand the grid
/// tiles, session bar and cards all use: `45s`, `12m`, `3h`, `2d`.
///
/// Deliberately not a `RelativeDateTimeFormatter`: this reads as a running
/// clock beside a branch name and a diff stat, not as prose. "2d" belongs in
/// a 28pt tile bar; "2 days ago" does not.
///
/// Shared because it had been copied twice — `TileMetaRow.elapsed(since:)`
/// and `SessionCard.elapsedTime` were the same switch with the same
/// boundaries, and a third caller (the session bar) would have made three.
enum SessionElapsed {
    static func since(_ start: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(start)
        switch interval {
        case ..<0: return "0s"
        case ..<60: return "\(Int(interval))s"
        case ..<3600: return "\(Int(interval / 60))m"
        case ..<86400: return "\(Int(interval / 3600))h"
        default: return "\(Int(interval / 86400))d"
        }
    }
}
