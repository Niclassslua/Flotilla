import Foundation
import CompanionKit

/// A Mac running Flotilla that this phone is paired with.
struct MacHost: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var connection: MacConnectionState
    /// When the link last delivered anything. Shown only while unreachable.
    var lastSeen: Date

    var isReachable: Bool {
        if case .connected = connection { return true }
        return false
    }
}

enum MacConnectionState: Hashable, Sendable {
    case connecting
    case connected(path: NetworkPath, address: String)
    /// Not reachable right now; retried automatically.
    case unreachable
    /// The Mac refused this phone or proved to be a different Mac. Not retried
    /// until the user pairs again.
    case needsRepairing(RepairReason)

    enum RepairReason: Hashable, Sendable {
        case revoked
        case unknownDevice
        case identityChanged
        case versionMismatch

        var message: String {
            switch self {
            case .revoked: "This iPhone was removed on the Mac."
            case .unknownDevice: "The Mac no longer recognizes this iPhone."
            case .identityChanged: "This Mac's identity changed since you paired. If you didn't reinstall Flotilla or reset its companion settings, don't pair again."
            case .versionMismatch: "This app and Flotilla on the Mac use different protocol versions. Update both."
            }
        }
    }
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

/// A value that arrives from the Mac on request.
enum Remote<Value: Sendable>: Sendable {
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }
}

extension DiffStat {
    /// The Mac knows line counts before it knows files, so either counts.
    var hasChanges: Bool { files > 0 || additions > 0 || deletions > 0 }

    var compactSummary: String {
        files > 0 ? summary : "+\(additions) −\(deletions)"
    }
}
