import Foundation

struct FileDiff: Identifiable, Hashable, Sendable {
    enum Change: Hashable, Sendable {
        case added
        case modified
        case deleted
        case renamed(from: String)
    }

    var id: String { path }
    var path: String
    var change: Change
    var hunks: [DiffHunk]

    var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
    var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }

    var fileName: String { (path as NSString).lastPathComponent }
}

struct DiffHunk: Identifiable, Hashable, Sendable {
    let id = UUID()
    var header: String
    var lines: [DiffLine]
}

struct DiffLine: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case context
        case added
        case removed
    }

    let id = UUID()
    var kind: Kind
    var text: String

    var marker: String {
        switch kind {
        case .context: " "
        case .added: "+"
        case .removed: "−"
        }
    }
}

extension [FileDiff] {
    var stat: DiffStat {
        DiffStat(
            files: count,
            additions: reduce(0) { $0 + $1.additions },
            deletions: reduce(0) { $0 + $1.deletions }
        )
    }
}

extension DiffHunk {
    /// Builds a hunk from unified-diff body lines (`+`, `-`, or space prefixed).
    init(header: String, unified: String) {
        self.header = header
        self.lines = unified.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            if line.hasPrefix("+") { return DiffLine(kind: .added, text: String(line.dropFirst())) }
            if line.hasPrefix("-") { return DiffLine(kind: .removed, text: String(line.dropFirst())) }
            return DiffLine(kind: .context, text: line.hasPrefix(" ") ? String(line.dropFirst()) : line)
        }
    }
}

struct CommitSummary: Identifiable, Hashable, Sendable {
    var id: String { hash }
    var hash: String
    var subject: String
    var author: String
    var date: Date
    var isPushed: Bool
    var files: [FileDiff]

    var shortHash: String { String(hash.prefix(7)) }
}
