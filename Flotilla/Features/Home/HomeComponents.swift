import SwiftUI
import SessionKit
import SettingsKit
import DesignSystem

// MARK: - Fleet Statistics

/// Session counts by status, computed once per render rather than by filtering
/// `store.sessions` repeatedly at each call site the way `DetailColumn` does.
struct HomeFleetStats {
    let total: Int
    private let counts: [SessionStatus: Int]

    init(sessions: [Session]) {
        total = sessions.count
        // A session with no status yet contributes to no bucket — nothing to
        // show in the fleet legend until it is observed.
        counts = sessions.reduce(into: [:]) { partial, session in
            if let status = session.status { partial[status, default: 0] += 1 }
        }
    }

    func count(_ status: SessionStatus) -> Int {
        counts[status] ?? 0
    }

    /// Statuses that actually occur, in `StatusPresentation.attentionOrder` so
    /// the most actionable state always reads first.
    var presentStatuses: [SessionStatus] {
        StatusPresentation.attentionOrder.filter { count($0) > 0 }
    }

    var needsAttention: Int { count(.waitingForInput) }
    var working: Int { count(.working) }
    var crashed: Int { count(.crashed) }

    /// One-line summary for the window subtitle and compact strips.
    var summary: String {
        guard total > 0 else { return "No sessions yet" }
        let parts = presentStatuses.map { "\(count($0)) \(StatusPresentation.compactLabel(for: $0))" }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Timestamp Formatting

enum HomeTimestamp {
    /// "now" / "5m" / "3h" / "2d" — matches the register `SessionCard` uses.
    static func compact(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        switch elapsed {
        case ..<60: return "now"
        case ..<3600: return "\(Int(elapsed / 60))m"
        case ..<86_400: return "\(Int(elapsed / 3600))h"
        default: return "\(Int(elapsed / 86_400))d"
        }
    }
}

// MARK: - Activity Line

/// The agent's most recent terminal line. Only rendered for sessions that are
/// actually producing output — a finished session's last line is stale noise.
struct HomeActivityLine: View {
    let session: Session
    let activityStore: SessionActivityStore?
    var font: Font = FlotillaTypography.caption2

    private var isLive: Bool {
        session.status == .working || session.status == .waitingForInput
    }

    var body: some View {
        Group {
            if isLive, let line = activityStore?.lastOutputLine(for: session.id) {
                Text(line)
                    .font(font.monospaced())
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .onAppear {
            if isLive { activityStore?.watch(session.id) }
        }
        .onDisappear {
            activityStore?.unwatch(session.id)
        }
    }
}
