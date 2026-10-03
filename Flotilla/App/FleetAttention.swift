import AppKit
import Observation
import SessionKit

/// The fleet sorted by what it wants from the user, for surfaces outside the
/// main window: the Dock badge and the menu bar extra. Pure, so the counting
/// rule is testable without AppKit.
struct FleetAttention: Equatable {
    /// Blocked on the user — the same set Home's Needs you widget lists —
    /// plus sessions whose CI is failing, which need the user just as much
    /// even though the agent itself is not stuck.
    let waiting: [Session]
    /// The subset of `waiting` that is there because of CI.
    let ciFailing: Set<UUID>
    let readyForReview: [Session]
    let crashed: [Session]
    let working: [Session]

    init(sessions: [Session], ciFailing: Set<UUID> = []) {
        // Oldest first within a group: the session that has sat longest is
        // the one to deal with next.
        let ordered = sessions.sorted { Self.since($0) < Self.since($1) }
        // A session appears once, in the most urgent group it qualifies for:
        // red CI on a session that is also Ready for Review is a reason to
        // act, not something to review.
        let needsYou = ordered.filter { $0.status == .waitingForInput || ciFailing.contains($0.id) }
        let needsYouIDs = Set(needsYou.map(\.id))
        waiting = needsYou
        self.ciFailing = ciFailing.intersection(needsYouIDs)
        readyForReview = ordered.filter { $0.status == .readyForReview && !needsYouIDs.contains($0.id) }
        crashed = ordered.filter { $0.status == .crashed && !needsYouIDs.contains($0.id) }
        working = ordered.filter { $0.status == .working && !needsYouIDs.contains($0.id) }
    }

    /// Only sessions that are blocked count. Ready and crashed sessions can
    /// wait for the user indefinitely, so counting them would leave the badge
    /// permanently lit and teach the user to ignore it.
    var dockBadgeLabel: String? {
        waiting.isEmpty ? nil : String(waiting.count)
    }

    private static func since(_ session: Session) -> Date {
        session.statusChangedAt ?? session.lastActiveAt
    }
}

/// Keeps the Dock tile's badge equal to the number of waiting sessions while
/// the setting allows it. Runs independently of any window, so the badge
/// stays correct after the main window is closed.
@MainActor
final class DockBadgeController {
    private let sessions: @MainActor () -> [Session]
    private let ciFailing: @MainActor () -> Set<UUID>
    private let isEnabled: @MainActor () -> Bool
    private let apply: @MainActor (String?) -> Void
    private var appliedLabel: String??

    init(
        sessions: @escaping @MainActor () -> [Session],
        ciFailing: @escaping @MainActor () -> Set<UUID> = { [] },
        isEnabled: @escaping @MainActor () -> Bool,
        apply: @escaping @MainActor (String?) -> Void = { NSApp?.dockTile.badgeLabel = $0 }
    ) {
        self.sessions = sessions
        self.ciFailing = ciFailing
        self.isEnabled = isEnabled
        self.apply = apply
    }

    func start() {
        update()
    }

    private func update() {
        let label = withObservationTracking {
            isEnabled() ? FleetAttention(sessions: sessions(), ciFailing: ciFailing()).dockBadgeLabel : nil
        } onChange: { [weak self] in
            Task { @MainActor in self?.update() }
        }
        guard appliedLabel != .some(label) else { return }
        appliedLabel = .some(label)
        apply(label)
    }
}
