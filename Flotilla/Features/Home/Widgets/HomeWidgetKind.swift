import Foundation
import SessionKit
import SettingsKit

/// A widget size on the Home grid: S 1×1, M 2×1, L 2×2, W full-row×1 — the
/// same family the macOS/iOS widget gallery uses.
enum HomeWidgetSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large, wide

    /// Column span at any column count; `wide` always fills the row, so its
    /// width is resolved by the layout, not fixed here.
    var columnSpan: Int {
        switch self {
        case .small: 1
        case .medium, .wide: 2
        case .large: 2
        }
    }

    var rowSpan: Int {
        self == .large ? 2 : 1
    }
}

/// What data a widget needs `HomeInsights` to have loaded. The grid unions
/// this across every placed widget so a Home with no Hot files widget never
/// pays for per-file churn.
enum HomeDataNeed: Hashable, Sendable {
    case repoState
    case commitActivity
    case reviewQueue
    case fileChurn
    case permissionLog
    case screenshots
}

/// Every widget the grid can place. Raw values are what's persisted in
/// `HomeWidgetEntry.kind` — stable once shipped, since renaming one silently
/// drops it from existing users' saved layouts.
enum HomeWidgetKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case needsYou
    case reviewQueue
    case looseEnds
    case agentScreenshots
    case streak
    case today
    case busiestHours
    case hotFiles
    case topPermissions
    case contributions
    case weeklyRhythm
    case agentShare
    case codebaseGrowth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .reviewQueue: "Ready for review"
        case .looseEnds: "Loose ends"
        case .agentScreenshots: "Agent screenshots"
        case .streak: "Streak"
        case .today: "Today"
        case .busiestHours: "Busiest hours"
        case .hotFiles: "Hot files"
        case .topPermissions: "Top permissions"
        case .contributions: "Contributions"
        case .weeklyRhythm: "Weekly rhythm"
        case .agentShare: "Agent share"
        case .codebaseGrowth: "Codebase growth"
        }
    }

    var glyph: String {
        switch self {
        case .needsYou: "hand.raised.fill"
        case .reviewQueue: "checkmark.circle.fill"
        case .looseEnds: "scissors"
        case .agentScreenshots: "camera.viewfinder"
        case .streak: "flame.fill"
        case .today: "sun.max.fill"
        case .busiestHours: "clock.fill"
        case .hotFiles: "flame.fill"
        case .topPermissions: "lock.shield.fill"
        case .contributions: "square.grid.3x3.fill"
        case .weeklyRhythm: "waveform.path.ecg"
        case .agentShare: "chart.pie.fill"
        case .codebaseGrowth: "chart.line.uptrend.xyaxis"
        }
    }

    /// Sizes the widget has a real layout for, first is the default.
    var supportedSizes: [HomeWidgetSize] {
        switch self {
        case .needsYou: [.medium, .small, .large]
        case .reviewQueue: [.large, .medium]
        case .looseEnds: [.medium, .small]
        case .agentScreenshots: [.large, .medium, .wide]
        case .streak: [.small]
        case .today: [.small, .medium]
        case .busiestHours: [.medium, .wide]
        case .hotFiles: [.medium, .large]
        case .topPermissions: [.medium, .small]
        case .contributions: [.wide, .medium]
        case .weeklyRhythm: [.medium, .wide]
        case .agentShare: [.medium, .small, .large]
        case .codebaseGrowth: [.wide, .medium]
        }
    }

    var defaultSize: HomeWidgetSize { supportedSizes[0] }

    /// Time-window choices in days, first is the default; `nil` if the
    /// widget has no window setting.
    var timeWindowOptionsDays: [Int]? {
        switch self {
        case .busiestHours: [30, 90, 365]
        case .hotFiles: [7, 30]
        case .topPermissions: [7, 30]
        case .weeklyRhythm: [14, 28, 56]
        case .agentShare: [7, 30, 90]
        case .codebaseGrowth: [84, 182]
        default: nil
        }
    }

    var defaultTimeWindowDays: Int? { timeWindowOptionsDays?.first }

    var hasAgentFilter: Bool {
        self == .topPermissions || self == .agentScreenshots
    }

    /// Every widget supports a project filter.
    var hasProjectFilter: Bool { true }

    var dataNeeds: Set<HomeDataNeed> {
        switch self {
        case .needsYou, .reviewQueue: [.reviewQueue]
        case .looseEnds: [.repoState]
        case .agentScreenshots: [.screenshots]
        case .streak, .today, .contributions, .weeklyRhythm, .agentShare, .codebaseGrowth, .busiestHours:
            [.commitActivity]
        case .hotFiles: [.fileChurn]
        case .topPermissions: [.permissionLog]
        }
    }

    /// Today's fixed layout, kept as the default for everyone who hasn't
    /// customized Home — matches what `HomeStatsSection` showed before the
    /// grid existed.
    static let defaultLayout: [HomeWidgetEntry] = [
        HomeWidgetEntry(kind: HomeWidgetKind.contributions.rawValue, size: HomeWidgetSize.wide.rawValue),
        HomeWidgetEntry(kind: HomeWidgetKind.weeklyRhythm.rawValue, size: HomeWidgetSize.medium.rawValue),
        HomeWidgetEntry(kind: HomeWidgetKind.agentShare.rawValue, size: HomeWidgetSize.medium.rawValue),
        HomeWidgetEntry(kind: HomeWidgetKind.codebaseGrowth.rawValue, size: HomeWidgetSize.wide.rawValue),
    ]
}

extension HomeWidgetEntry {
    /// `nil` when the stored kind or size is unrecognized — dropped rather
    /// than crashing the grid over one bad entry from a newer app version.
    var resolvedKind: HomeWidgetKind? { HomeWidgetKind(rawValue: kind) }
    var resolvedSize: HomeWidgetSize? { HomeWidgetSize(rawValue: size) }
}
