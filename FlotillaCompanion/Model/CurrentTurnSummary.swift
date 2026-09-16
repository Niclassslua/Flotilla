import Foundation
import CompanionKit

/// Pure formatting for the compact "what's happening in this turn" recap
/// shown under the session header — a snapshot computed once per render,
/// not `WorkingIndicator`'s live per-second ticker near the composer.
enum CurrentTurnSummaryFormatting {
    /// `nil` when there's nothing worth saying (no active tool, no changes).
    static func detail(inFlight: ToolCall?, diffStat: DiffStat?, now: Date = .now) -> String? {
        var parts: [String] = []
        if let inFlight {
            parts.append("Running \(inFlight.subject ?? inFlight.tool) · \(compactElapsed(since: inFlight.startedAt, now: now))")
        }
        if let diffStat, diffStat.hasChanges {
            // `compactSummary` already omits the file count when it's unknown.
            parts.append(diffStat.compactSummary)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func compactElapsed(since start: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }
}
