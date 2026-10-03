import SwiftUI
import Observation
import SessionKit
import GitKit
import DesignSystem

enum SessionGitSidebarTab: String, CaseIterable, Identifiable, Sendable {
    case changes
    case branches
    case log
    case checks

    var id: Self { self }

    var title: String {
        switch self {
        case .changes: "Changes"
        case .branches: "Branches"
        case .log: "Log"
        case .checks: "Checks"
        }
    }

    var systemImage: String {
        switch self {
        case .changes: "arrow.left.arrow.right"
        case .branches: "arrow.triangle.branch"
        case .log: "clock.arrow.circlepath"
        case .checks: "checklist"
        }
    }
}

enum SessionGitChangeMode: String, CaseIterable, Identifiable, Sendable {
    case uncommitted
    case versusDefault

    var id: Self { self }
}

enum SessionGitChangeKind: Equatable, Sendable {
    case added
    case deleted
    case modified
    case renamed

    var symbol: String {
        switch self {
        case .added: "A"
        case .deleted: "D"
        case .modified: "M"
        case .renamed: "R"
        }
    }

    var label: String {
        switch self {
        case .added: "Added"
        case .deleted: "Deleted"
        case .modified: "Modified"
        case .renamed: "Renamed"
        }
    }
}

enum SessionGitStageState: Equatable, Sendable {
    case unstaged
    case staged
    case partiallyStaged
}

struct SessionGitChangeItem: Identifiable, Sendable {
    let path: String
    let kind: SessionGitChangeKind
    let stat: GitDiffStat
    let stageState: SessionGitStageState?

    var id: String { path }

    var filename: String {
        (path as NSString).lastPathComponent
    }

    var directory: String? {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty || parent == "." ? nil : parent
    }
}

