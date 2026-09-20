import Foundation
import SwiftUI

/// Which navigator layout to draw. Four explorations of the same information,
/// switched live from **Workspace ▸ Navigator Layout** (or pinned at launch
/// with `FLOTILLA_SIDEBAR_DESIGN=1…4` for the screenshot sweep) so they can be
/// compared in the real app before one is folded into `FleetSidebar` and the
/// others are deleted.
///
/// Parked here rather than inline for the same reason
/// `Features/CreateSession/Designs/Redesigns/` exists: an exploration that
/// lives in its own file can be removed in one commit.
enum SidebarDesign: Int, CaseIterable, Sendable, Identifiable {
    /// Today's row, under a project header that finally outweighs it.
    case elevatedHeader = 1
    /// The project's accent drawn as a rail down its session block; rows lose
    /// the provider tile and the status word to buy the title its width back.
    case accentRail = 2
    /// Each project is a card: tinted header strip, sessions inside it on one
    /// line apiece, separated by hairlines.
    case projectCard = 3
    /// A status bar at the row's leading edge, and the branch back on a second
    /// line now that nothing else is competing for the width.
    case statusForward = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .elevatedHeader: "Elevated Header"
        case .accentRail: "Accent Rail"
        case .projectCard: "Project Card"
        case .statusForward: "Status Forward"
        }
    }

    /// `FLOTILLA_SIDEBAR_DESIGN=1…4`, for the screenshot sweep, which has no
    /// way to work a menu. Absent in an ordinary launch, where the choice is
    /// the store's.
    static var launchOverride: SidebarDesign? {
        guard let raw = ProcessInfo.processInfo.environment["FLOTILLA_SIDEBAR_DESIGN"],
              let value = Int(raw)
        else { return nil }
        return SidebarDesign(rawValue: value)
    }
}

/// Which navigator layout is on screen, switchable live from
/// **Workspace ▸ Navigator Layout** so the four can be compared in the real
/// app rather than from screenshots.
///
/// Its own `UserDefaults` key rather than a field on `AppSettings`: this is
/// exploration scaffolding with a deletion date, and a key written in one
/// place disappears with the file instead of leaving a decode fallback behind
/// in `SettingsKit` forever.
@Observable
@MainActor
final class SidebarDesignStore {
    private static let defaultsKey = "sidebar.design"

    var design: SidebarDesign {
        didSet {
            guard design != oldValue else { return }
            UserDefaults.standard.set(design.rawValue, forKey: Self.defaultsKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        if let override = SidebarDesign.launchOverride {
            design = override
            return
        }
        let stored = defaults.integer(forKey: Self.defaultsKey)
        design = SidebarDesign(rawValue: stored) ?? .elevatedHeader
    }
}

private struct SidebarDesignKey: EnvironmentKey {
    static let defaultValue: SidebarDesign = .elevatedHeader
}

extension EnvironmentValues {
    /// Read by every navigator row. Set once at the shell root, the way
    /// `editorFontSize` is (`FlotillaApp.body`).
    var sidebarDesign: SidebarDesign {
        get { self[SidebarDesignKey.self] }
        set { self[SidebarDesignKey.self] = newValue }
    }
}

/// Where a session row sits inside its project's block. Only the designs that
/// draw group-level chrome — a card's rounded corners, a rail's end caps —
/// read it, but every row is told, because a row cannot see its siblings.
enum SidebarRowPosition {
    case only, first, middle, last

    var isFirst: Bool { self == .only || self == .first }
    var isLast: Bool { self == .only || self == .last }
}
