import CryptoKit
import Foundation

/// Which side of a diff a line or a comment belongs to.
///
/// Mirrors git's own pre-image/post-image split, and the two columns of a
/// side-by-side view. A context line exists on both sides; everything that
/// anchors to one — a comment, a selection — has to say which.
public enum DiffSide: String, Equatable, Sendable, CaseIterable {
    /// The pre-image: the file as it was. Removed lines live only here.
    case old
    /// The post-image: the file as the agent left it. Added lines live only here.
    case new
}

/// One line of a unified diff with the file line numbers git only states once,
/// in the hunk header.
///
/// `FileDiffHunk` keeps raw `+`/`-`/` `-prefixed strings, which is enough to
/// paint a patch but not to review one: a comment has to anchor to a real line
/// number so it survives a refresh that re-parses the diff, and a side-by-side
/// view has to know which numbers to print in each gutter.
public struct DiffLine: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case context
        case added
        case removed
    }

    public var kind: Kind
    /// Line number in the pre-image. `nil` for added lines.
    public var oldNumber: Int?
    /// Line number in the post-image. `nil` for removed lines.
    public var newNumber: Int?
    /// Content with git's leading marker stripped.
    public var text: String
    /// git emitted `\ No newline at end of file` for this line.
    public var lacksTrailingNewline: Bool

    public init(
        kind: Kind,
        oldNumber: Int? = nil,
        newNumber: Int? = nil,
        text: String,
        lacksTrailingNewline: Bool = false
    ) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
        self.lacksTrailingNewline = lacksTrailingNewline
    }

    /// The line number shown for `side`, or `nil` if the line is absent there.
    public func number(on side: DiffSide) -> Int? {
        switch side {
        case .old: oldNumber
        case .new: newNumber
        }
    }

    /// Where a comment on this line belongs. Added and context lines anchor to
    /// the post-image — the code that is actually there now; removed lines can
    /// only anchor to the pre-image.
    public var commentSide: DiffSide {
        kind == .removed ? .old : .new
    }
}

/// A `FileDiffHunk` with its header decoded and its lines numbered.
public struct ReviewHunk: Equatable, Sendable {
    /// The raw `@@ … @@` line, kept verbatim for display.
    public var header: String
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// The text trailing the second `@@` — usually the enclosing declaration.
    public var section: String
    public var lines: [DiffLine]

    public init(
        header: String,
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        section: String,
        lines: [DiffLine]
    ) {
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = lines
    }
}

/// One row of a side-by-side rendering: the old-side line, the new-side line,
/// or both when they pair up.
///
/// Never has both sides `nil`.
public struct DiffRow: Equatable, Sendable {
    public var left: DiffLine?
    public var right: DiffLine?

    public init(left: DiffLine?, right: DiffLine?) {
        self.left = left
        self.right = right
    }

    /// Both sides carry the same unchanged line.
    public var isContext: Bool {
        left?.kind == .context && right?.kind == .context
    }

    /// A removal paired with an addition — the two halves of a modified line.
    public var isModification: Bool {
        left?.kind == .removed && right?.kind == .added
    }
}

/// Turns git's patch text into something reviewable: numbered lines, and the
/// old/new pairing a two-column view needs.
public enum ReviewDiff {
    /// Decodes `@@ -oldStart,oldCount +newStart,newCount @@ section`.
    ///
    /// Returns `nil` for a header that isn't in that form — including the
    /// synthetic `@@ new untracked file @@` header `changesCompared(to:at:)`
    /// invents for untracked files, which carries no numbers at all.
    public static func parseHunkHeader(
        _ header: String
    ) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String)? {
        guard header.hasPrefix("@@") else { return nil }
        let afterOpening = header.dropFirst(2)
        guard let closing = afterOpening.range(of: "@@") else { return nil }

        let ranges = afterOpening[..<closing.lowerBound].split(separator: " ")
        guard ranges.count >= 2,
              ranges[0].hasPrefix("-"),
              ranges[1].hasPrefix("+"),
              let old = parseRange(ranges[0]),
              let new = parseRange(ranges[1])
        else { return nil }

        return (
            oldStart: old.start,
            oldCount: old.count,
            newStart: new.start,
            newCount: new.count,
            section: String(afterOpening[closing.upperBound...])
                .trimmingCharacters(in: .whitespaces)
        )
    }

    /// `-12,7` → `(12, 7)`; `-12` → `(12, 1)`, git's shorthand for a
    /// single-line range.
    private static func parseRange(_ field: Substring) -> (start: Int, count: Int)? {
        let numbers = field.dropFirst().split(separator: ",")
        guard let first = numbers.first, let start = Int(first) else { return nil }
        let count = numbers.count > 1 ? (Int(numbers[1]) ?? 1) : 1
        return (start, count)
    }

    /// Numbers one hunk's raw lines.
    ///
    /// A header without usable numbers (an untracked file's synthetic hunk)
    /// falls back to counting from line 1 on both sides, which is correct for
    /// a whole-file addition and harmless otherwise.
    public static func review(_ hunk: FileDiffHunk) -> ReviewHunk {
        let parsed = parseHunkHeader(hunk.header)
        var oldNumber = parsed?.oldStart ?? 1
        var newNumber = parsed?.newStart ?? 1

        var lines: [DiffLine] = []
        for raw in hunk.lines {
            // git's "no newline" marker annotates the line before it rather
            // than being a line of its own.
            if raw.hasPrefix("\\") {
                if !lines.isEmpty { lines[lines.count - 1].lacksTrailingNewline = true }
                continue
            }

            let marker = raw.first
            let text = raw.isEmpty ? "" : String(raw.dropFirst())
            switch marker {
            case "+":
                lines.append(DiffLine(kind: .added, newNumber: newNumber, text: text))
                newNumber += 1
            case "-":
                lines.append(DiffLine(kind: .removed, oldNumber: oldNumber, text: text))
                oldNumber += 1
            default:
                // A completely empty line is an unchanged blank line: git
                // writes the leading space, but trailing whitespace is easily
                // stripped in transit.
                lines.append(
                    DiffLine(
                        kind: .context,
                        oldNumber: oldNumber,
                        newNumber: newNumber,
                        text: raw.isEmpty ? "" : text
                    )
                )
                oldNumber += 1
                newNumber += 1
            }
        }

        return ReviewHunk(
            header: hunk.header,
            oldStart: parsed?.oldStart ?? 1,
            oldCount: parsed?.oldCount ?? 0,
            newStart: parsed?.newStart ?? 1,
            newCount: parsed?.newCount ?? lines.count,
            section: parsed?.section ?? "",
            lines: lines
        )
    }

    public static func review(_ hunks: [FileDiffHunk]) -> [ReviewHunk] {
        hunks.map(review)
    }

    /// Pairs a hunk's lines into two-column rows.
    ///
    /// Within a run of changes, the *n*th removal is shown opposite the *n*th
    /// addition — the convention every side-by-side viewer uses, because a
    /// modified line reads as one row rather than as a deletion far above its
    /// replacement. An unequal run leaves the shorter side empty for the
    /// remainder.
    public static func sideBySideRows(for hunk: ReviewHunk) -> [DiffRow] {
        var rows: [DiffRow] = []
        var removed: [DiffLine] = []
        var added: [DiffLine] = []

        func flushRun() {
            for index in 0..<max(removed.count, added.count) {
                rows.append(
                    DiffRow(
                        left: index < removed.count ? removed[index] : nil,
                        right: index < added.count ? added[index] : nil
                    )
                )
            }
            removed = []
            added = []
        }

        for line in hunk.lines {
            switch line.kind {
            case .removed: removed.append(line)
            case .added: added.append(line)
            case .context:
                flushRun()
                rows.append(DiffRow(left: line, right: line))
            }
        }
        flushRun()
        return rows
    }

    /// A stable digest of a file's diff, used to tell whether the file changed
    /// since the reviewer marked it viewed.
    ///
    /// Covers headers as well as line content: a hunk that moved without its
    /// text changing is still a different diff to review.
    public static func fingerprint(for hunks: [FileDiffHunk]) -> String {
        var hasher = SHA256()
        for hunk in hunks {
            hasher.update(data: Data(hunk.header.utf8))
            hasher.update(data: Data([0]))
            for line in hunk.lines {
                hasher.update(data: Data(line.utf8))
                hasher.update(data: Data([0]))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
