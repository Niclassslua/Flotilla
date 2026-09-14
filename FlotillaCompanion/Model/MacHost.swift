import Foundation

/// A Mac running Flotilla that this phone is paired with.
struct MacHost: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var isReachable: Bool
    /// When the link last delivered anything. Shown only while unreachable.
    var lastSeen: Date
}

/// The one-line fleet summary for a Mac: `3 working · 1 needs you`.
///
/// Computed in one place because the same copy is meant to become the fleet
/// Live Activity later.
struct FleetSummary: Equatable, Sendable {
    var working: Int
    var needsYou: Int
    var total: Int

    init(sessions: [CompanionSession]) {
        working = sessions.filter { $0.status == .working && !$0.needsYou }.count
        needsYou = sessions.filter(\.needsYou).count
        total = sessions.count
    }

    /// The neutral part of the summary. `needsYouText` is kept apart so the
    /// row can colour it.
    var workingText: String? {
        if working > 0 { return "\(working) working" }
        if needsYou == 0 { return total == 0 ? "No sessions" : "\(total) idle" }
        return nil
    }

    var needsYouText: String? {
        needsYou > 0 ? "\(needsYou) needs you" : nil
    }
}
