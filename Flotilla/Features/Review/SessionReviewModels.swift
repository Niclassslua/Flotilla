import Foundation
import GitKit
import SessionKit

/// How a file's diff is laid out.
enum ReviewDiffMode: String, CaseIterable, Identifiable, Sendable {
    /// One column, additions and removals interleaved as git wrote them.
    case inline
    /// Two columns, the pre-image opposite the post-image.
    case sideBySide

    var id: Self { self }

    var title: String {
        switch self {
        case .inline: "Inline"
        case .sideBySide: "Side by Side"
        }
    }

    var systemImage: String {
        switch self {
        case .inline: "list.bullet.rectangle"
        case .sideBySide: "rectangle.split.2x1"
        }
    }
}

/// How many files the diff pane shows at once.
enum ReviewFileDisplay: String, CaseIterable, Identifiable, Sendable {
    /// Every changed file in one scroll, in path order.
    case allFiles
    /// Only the file selected in the file list.
    case singleFile

    var id: Self { self }

    var title: String {
        switch self {
        case .allFiles: "All Files"
        case .singleFile: "Single File"
        }
    }

    var systemImage: String {
        switch self {
        case .allFiles: "square.stack"
        case .singleFile: "doc"
        }
    }
}

/// A changed file with everything the review needs to draw a row for it: the
/// git change itself, its decoded hunks, and the reviewer's own state.
struct ReviewFile: Identifiable, Equatable {
    let change: GitCommitFileChange
    let hunks: [ReviewHunk]
    /// SHA of `change.hunks`, compared against a stored `ReviewedFile` to tell
    /// whether a tick still refers to the diff on screen.
    let fingerprint: String
    var isViewed: Bool
    var commentCount: Int

    var id: String { change.path }
    var path: String { change.path }

    var filename: String { (path as NSString).lastPathComponent }

    var directory: String? {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty || parent == "." ? nil : parent
    }

    /// A file git could produce no patch for — a binary, or a pure rename.
    var hasNoRenderableDiff: Bool {
        hunks.allSatisfy(\.lines.isEmpty)
    }

    var emptyDiffExplanation: String {
        switch change.kind {
        case .renamed, .copied: "No content changes — the file only moved."
        default: "No textual diff (this may be a binary file)."
        }
    }
}
