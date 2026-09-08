import SwiftUI
import GitKit
import DesignSystem

/// Presentation for a file's *change kind* — added, modified, deleted, and so
/// on — shared by the Changes page and the commit inspector so both speak one
/// visual language.
///
/// The Changes page previously coloured rows by staging area (staged = green,
/// everything else = red), which painted an entire dirty working tree red and
/// told the reader nothing about what had actually happened to each file. Kind
/// is the property worth encoding in colour; staging is already carried by the
/// section a row sits in.
extension GitCommitFileChange.Kind {
    /// Single-letter marker matching `git status --short` / `--name-status`.
    var marker: String {
        switch self {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        case .unmerged: return "U"
        }
    }

    /// Matches `GitSidebarChangeRow` in the session Git sidebar, which already
    /// settled this palette: amber for modified rather than the accent, which
    /// is close enough to `diffRemoved` that M and D read as the same colour.
    var color: Color {
        switch self {
        case .added: return FlotillaColors.diffAdded
        case .deleted: return FlotillaColors.diffRemoved
        case .modified: return FlotillaColors.warning
        case .renamed, .copied: return FlotillaColors.statusReady
        case .typeChanged, .unmerged: return FlotillaColors.accent
        }
    }

    var label: String {
        switch self {
        case .added: return "Added"
        case .modified: return "Modified"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .copied: return "Copied"
        case .typeChanged: return "Type changed"
        case .unmerged: return "Conflicted"
        }
    }

    /// Maps one porcelain-v1 status character (index or worktree column).
    /// Returns `nil` for the unchanged column (a space), so callers can fall
    /// back to the other column.
    static func fromPorcelain(_ character: Character) -> GitCommitFileChange.Kind? {
        switch character {
        case "A", "?": return .added
        case "M": return .modified
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        case "U": return .unmerged
        default: return nil
        }
    }
}

extension GitStatus {
    /// The change kind for one working-tree diff entry. Staged rows read the
    /// index column, unstaged rows the worktree column; untracked files are new
    /// by definition. Anything git did not report (a diff observed a beat
    /// before status caught up) degrades to `.modified` rather than to a colour
    /// that would misrepresent it.
    func changeKind(for diff: FileDiff) -> GitCommitFileChange.Kind {
        if diff.stage == .untracked { return .added }
        guard let entry = entries.first(where: { $0.path == diff.path }) else { return .modified }
        let primary = diff.stage == .staged ? entry.indexStatus : entry.worktreeStatus
        let secondary = diff.stage == .staged ? entry.worktreeStatus : entry.indexStatus
        return GitCommitFileChange.Kind.fromPorcelain(primary)
            ?? GitCommitFileChange.Kind.fromPorcelain(secondary)
            ?? .modified
    }
}

/// Square kind marker: the `git status` letter on a tint of its own colour.
struct FileChangeKindBadge: View {
    let kind: GitCommitFileChange.Kind
    var size: CGFloat = 18

    var body: some View {
        Text(kind.marker)
            .font(.system(size: size * 0.56, weight: .bold, design: .monospaced))
            .foregroundStyle(kind.color)
            .frame(width: size, height: size)
            .background(
                kind.color.opacity(0.14),
                in: RoundedRectangle(cornerRadius: FlotillaRadius.control - 2, style: .continuous)
            )
            .accessibilityLabel(kind.label)
            .help(kind.label)
    }
}
