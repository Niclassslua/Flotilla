import Foundation
import SessionKit

/// Which sessions are assigned to the grid, and the actions that change that
/// assignment.
///
/// Membership lives in `gridSelectedSessionIDs` — an ordered list of session
/// IDs — capped at `dimensions.capacity` (columns × rows) so the grid never
/// tries to force more tiles into the layout than the picker asked for.
/// Every read and write prunes IDs that no longer match a live session, so a
/// deleted session's old slot doesn't count against capacity forever.
enum GridSelection {
    /// The sessions that should actually render, in saved order, capped at
    /// capacity. Extra selected sessions beyond capacity stay recorded — so
    /// widening the grid later reveals them again — but are not shown.
    static func visible(selectedIDs: [String], in sessions: [Session], capacity: Int) -> [Session] {
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id.uuidString, $0) })
        let ordered = selectedIDs.compactMap { byID[$0] }
        return Array(ordered.prefix(max(0, capacity)))
    }

    /// Every session assigned to the grid, live or queued past capacity —
    /// used by the sidebar to mark a row as a member even when its tile
    /// isn't currently showing.
    static func memberIDs(selectedIDs: [String], in sessions: [Session]) -> Set<UUID> {
        let known = Set(sessions.map(\.id.uuidString))
        return Set(selectedIDs.filter(known.contains).compactMap { UUID(uuidString: $0) })
    }
}

extension SettingsViewModel {
    /// Adds or removes one session from the grid. Adding is a no-op once the
    /// live (non-stale) selection already fills the grid's capacity.
    func toggleGridMembership(of sessionID: UUID, in sessions: [Session], capacity: Int) {
        let known = Set(sessions.map(\.id.uuidString))
        var ids = settings.workspace.gridSelectedSessionIDs.filter(known.contains)
        let key = sessionID.uuidString
        if let index = ids.firstIndex(of: key) {
            ids.remove(at: index)
        } else {
            guard ids.count < capacity else { return }
            ids.append(key)
        }
        settings.workspace.gridSelectedSessionIDs = ids
    }

    /// "Add all": fills the grid up to capacity from `candidates`, in their
    /// current order, leaving the existing selection in place.
    ///
    /// `candidates` is the *scoped* fleet — the sessions in the group the bar
    /// currently has lit — while `allSessions` is the whole fleet. The two
    /// are separate because stale-ID pruning has to be judged against every
    /// live session: pruning against the candidates alone would evict every
    /// member belonging to a different group the moment you pressed Add all
    /// inside one.
    func addAllToGrid(candidates: [Session], allSessions: [Session], capacity: Int) {
        let known = Set(allSessions.map(\.id.uuidString))
        var ids = settings.workspace.gridSelectedSessionIDs.filter(known.contains)
        for session in candidates where ids.count < capacity {
            let key = session.id.uuidString
            if !ids.contains(key) { ids.append(key) }
        }
        settings.workspace.gridSelectedSessionIDs = ids
    }

    /// "Empty grid": clears every session's grid membership.
    func emptyGrid() {
        settings.workspace.gridSelectedSessionIDs = []
    }
}
