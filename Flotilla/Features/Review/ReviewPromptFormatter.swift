import Foundation
import GitKit
import SessionKit

/// Turns a review into the message an agent receives.
///
/// A pure function of its inputs, with no view model and no I/O, because the
/// exact text is the whole contract with the agent: it has to say *where* each
/// remark applies precisely enough that the agent does not have to guess, and
/// that is worth testing directly.
enum ReviewPromptFormatter {

    /// Formats `comments` against the files they were written on.
    ///
    /// Comments are grouped by file and ordered file-comments-first then by
    /// line, so the agent reads each file's general remarks before the
    /// specific ones. Every line comment quotes the line it is attached to:
    /// line numbers alone go stale the moment the agent makes its first edit,
    /// whereas the quoted text stays findable.
    static func prompt(
        sessionTitle: String,
        branch: String?,
        comments: [ReviewComment],
        files: [ReviewFile]
    ) -> String {
        guard !comments.isEmpty else { return "" }

        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        let grouped = Dictionary(grouping: comments, by: \.filePath)
        let paths = grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        var lines: [String] = [heading(sessionTitle: sessionTitle, branch: branch, comments: comments, fileCount: paths.count)]

        for path in paths {
            lines.append("")
            lines.append("## \(path)")
            for comment in sorted(grouped[path] ?? []) {
                lines.append(contentsOf: render(comment, in: byPath[path]))
            }
        }

        lines.append("")
        lines.append("Please address these comments. If you disagree with one, say so rather than changing the code.")
        return lines.joined(separator: "\n")
    }

    private static func heading(
        sessionTitle: String,
        branch: String?,
        comments: [ReviewComment],
        fileCount: Int
    ) -> String {
        let commentLabel = comments.count == 1 ? "1 comment" : "\(comments.count) comments"
        let fileLabel = fileCount == 1 ? "1 file" : "\(fileCount) files"
        let location = branch.map { " (\($0))" } ?? ""
        return "Code review of \"\(sessionTitle)\"\(location) — \(commentLabel) across \(fileLabel)."
    }

    /// Whole-file remarks first, then by line, then by creation time so two
    /// comments on the same line keep the order they were written in.
    private static func sorted(_ comments: [ReviewComment]) -> [ReviewComment] {
        comments.sorted { lhs, rhs in
            switch (lhs.anchor.lineNumber, rhs.anchor.lineNumber) {
            case (nil, nil): return lhs.createdAt < rhs.createdAt
            case (nil, _): return true
            case (_, nil): return false
            case let (left?, right?):
                if left != right { return left < right }
                return lhs.createdAt < rhs.createdAt
            }
        }
    }

    private static func render(_ comment: ReviewComment, in file: ReviewFile?) -> [String] {
        var lines: [String] = []

        switch comment.anchor {
        case .file:
            lines.append("- **Whole file:** \(comment.body)")
        case let .line(side, number):
            // "removed" reads more clearly than "old side" for a line the
            // agent deleted, which is the only thing an old-side anchor is.
            let sideLabel = side == .old ? "removed" : "current"
            lines.append("- **Line \(number)** (\(sideLabel)):")
            if let text = lineText(file: file, side: side, number: number) {
                lines.append("  > `\(text)`")
            }
            lines.append("  \(comment.body)")
        }

        return lines
    }

    /// The source text of the anchored line, or `nil` when the anchor no
    /// longer resolves — in which case the comment is still delivered, just
    /// without a quote, rather than being silently dropped.
    private static func lineText(file: ReviewFile?, side: ReviewSide, number: Int) -> String? {
        guard let file else { return nil }
        let wanted: DiffSide = side == .old ? .old : .new
        for hunk in file.hunks {
            for line in hunk.lines where line.number(on: wanted) == number {
                // A removed line and a context line can share an old-side
                // number only across hunks, so the first match is the one.
                guard line.commentSide == wanted || line.kind == .context else { continue }
                let text = line.text.trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : text
            }
        }
        return nil
    }
}
