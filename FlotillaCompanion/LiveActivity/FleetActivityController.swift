@preconcurrency import ActivityKit
import CompanionKit
import DesignSystem
import Foundation

/// What the fleet Live Activity should show for one Mac right now.
struct FleetActivitySnapshot: Equatable {
    var macID: MacHost.ID
    var macName: String
    var state: FleetActivityAttributes.ContentState
    /// The app is in the background and about to drop the Mac. iOS may
    /// suspend it before it can say so, so the activity is handed a stale
    /// date instead and goes stale on its own.
    var goesStale: Bool
    /// Something is working or needs you. Only then does an activity start,
    /// and one that's running ends once this goes false.
    var isActive: Bool

    /// Sessions that keep the activity alive. A change here is what lets an
    /// activity the user dismissed come back.
    var urgentSessionIDs: Set<UUID> {
        Set(state.sessions.filter { $0.status != .ready }.map(\.id))
    }

    init(mac: MacHost, sessions: [CompanionSession], goesStale: Bool) {
        let ranked = sessions
            .compactMap(Self.activitySession)
            .sorted { lhs, rhs in
                lhs.since != rhs.since ? lhs.since > rhs.since : lhs.title < rhs.title
            }
        macID = mac.id
        macName = mac.name
        state = FleetActivityAttributes.ContentState(
            sessions: Array(ranked.prefix(FleetActivityAttributes.maxSessions)),
            activeCount: ranked.count,
            isLive: mac.isReachable,
            updatedAt: mac.lastSeen
        )
        self.goesStale = goesStale
        isActive = ranked.contains { $0.status != .ready }
    }

    /// `nil` for sessions the activity leaves out: unstarted ones, and
    /// reviews the user has already looked at.
    private static func activitySession(_ session: CompanionSession) -> FleetActivityAttributes.Session? {
        let status: FleetActivityAttributes.Status
        let detail: String
        if session.status == .crashed {
            status = .crashed
            detail = session.crashReason ?? "Crashed"
        } else if let failure = session.failure {
            status = .waiting
            detail = failure
        } else {
            switch session.status {
            case .waitingForInput:
                status = .waiting
                detail = session.attentionSummary
                    ?? StatusPresentation.label(for: session.status, waitingReason: session.waitingReason)
            case .working:
                status = .working
                detail = session.branch ?? "Working"
            case .readyForReview where !session.reviewAcknowledged:
                status = .ready
                detail = session.diffStat.map { "Ready for review · \($0.files) \($0.files == 1 ? "file" : "files")" }
                    ?? "Ready for review"
            default:
                return nil
            }
        }
        return FleetActivityAttributes.Session(
            id: session.id,
            title: String(session.title.prefix(60)),
            agent: session.agent,
            status: status,
            detail: String(detail.prefix(80)),
            since: session.updatedAt
        )
    }
}

/// Starts, updates, and ends the one fleet Live Activity. Local-only — no
/// push token is requested (docs/companion.md decision #6).
@MainActor
final class FleetActivityController {
    private var activity: Activity<FleetActivityAttributes>?
    private var hasAdoptedExisting = false
    /// The urgent sessions at the moment the user swiped the activity away.
    /// It stays gone until that set changes.
    private var dismissedFor: Set<UUID>?
    /// Chains calls to `sync` so one always finishes touching `activity`
    /// before the next starts. `RootView` restarts its `.task(id:)` on
    /// almost every session update, so without this, two overlapping calls
    /// can each suspend at `Activity.request` while `activity` is still
    /// `nil`, and both end up requesting one — leaving a duplicate, frozen
    /// activity behind that nothing ever updates again.
    private var lastSync: Task<Void, Never>?

    /// How long a finished fleet's final state lingers on the Lock Screen.
    private static let finishedLinger: TimeInterval = 15 * 60

    /// Matches `RootView.disconnectGrace`: once it passes in the background
    /// the phone stops hearing from the Mac.
    static let backgroundStaleAfter: TimeInterval = 2.5

    func sync(_ snapshot: FleetActivitySnapshot?) async {
        let previous = lastSync
        let task = Task { [weak self] in
            await previous?.value
            await self?.performSync(snapshot)
        }
        lastSync = task
        await task.value
    }

    private func performSync(_ snapshot: FleetActivitySnapshot?) async {
        adoptExistingIfNeeded(macID: snapshot?.macID)

        if let current = activity {
            switch current.activityState {
            case .dismissed:
                dismissedFor = snapshot?.urgentSessionIDs
                activity = nil
            case .ended:
                activity = nil
            default:
                if current.attributes.macID != snapshot?.macID {
                    await current.end(nil, dismissalPolicy: .immediate)
                    activity = nil
                }
            }
        }

        guard let snapshot else { return }
        let staleDate = snapshot.goesStale ? Date.now + Self.backgroundStaleAfter : nil
        let content = ActivityContent(state: snapshot.state, staleDate: staleDate)

        guard snapshot.isActive else {
            dismissedFor = nil
            if let current = activity {
                activity = nil
                await current.end(content, dismissalPolicy: .after(.now + Self.finishedLinger))
            }
            return
        }

        if let current = activity {
            await current.update(content)
            return
        }

        guard snapshot.state.isLive, !snapshot.goesStale,
              dismissedFor != snapshot.urgentSessionIDs,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        dismissedFor = nil
        let attributes = FleetActivityAttributes(macID: snapshot.macID, macName: snapshot.macName)
        activity = try? Activity.request(attributes: attributes, content: content)
    }

    /// Picks up the activity a previous launch left running, so a relaunch
    /// doesn't stack a second one, and ends any others.
    private func adoptExistingIfNeeded(macID: MacHost.ID?) {
        guard !hasAdoptedExisting else { return }
        hasAdoptedExisting = true
        for existing in Activity<FleetActivityAttributes>.activities {
            let isRunning = existing.activityState == .active || existing.activityState == .stale
            if activity == nil, isRunning, existing.attributes.macID == macID {
                activity = existing
            } else if isRunning {
                Task { await existing.end(nil, dismissalPolicy: .immediate) }
            }
        }
    }
}
