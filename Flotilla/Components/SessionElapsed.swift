import Foundation

/// Elapsed-time shorthand: compact units for cards and history, and minute
/// precision for the focused session bar.
///
/// Deliberately not a `RelativeDateTimeFormatter`: this reads as a running
/// clock beside a branch name and a diff stat, not as prose. "2d" belongs in
/// a 28pt tile bar; "2 days ago" does not.
///
enum SessionElapsed {
    /// Minute precision for the focused session's running clock.
    static func detailedSince(_ start: Date, now: Date = Date()) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(start)))
        let minutes = seconds / 60
        let hours = minutes / 60
        if seconds < 60 { return "\(seconds)s" }
        if minutes < 60 { return "\(minutes)m" }
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h \(minutes % 60)m"
    }

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
