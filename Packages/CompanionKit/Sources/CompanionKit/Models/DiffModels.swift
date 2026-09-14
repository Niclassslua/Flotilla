import Foundation

public struct FileDiff: Identifiable, Hashable, Codable, Sendable {
    public enum Change: Hashable, Codable, Sendable {
        case added
        case modified
        case deleted
        case renamed(from: String)
    }

    public var id: String { path }
    public var path: String
    public var change: Change
    public var hunks: [DiffHunk]

    public init(path: String, change: Change, hunks: [DiffHunk]) {
        self.path = path
        self.change = change
        self.hunks = hunks
    }

    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }

    public var fileName: String { (path as NSString).lastPathComponent }
}

public struct DiffHunk: Identifiable, Hashable, Codable, Sendable {
    public var id: String { header + "#\(lines.count)" }
    public var header: String
    public var lines: [DiffLine]

    public init(header: String, lines: [DiffLine]) {
        self.header = header
        self.lines = lines
    }

    /// Builds a hunk from unified-diff body lines (`+`, `-`, or space prefixed).
    public init(header: String, unified: String) {
        self.init(header: header, unifiedLines: unified.components(separatedBy: "\n"))
    }

    public init(header: String, unifiedLines: [String]) {
        self.header = header
        self.lines = unifiedLines.map { line in
            if line.hasPrefix("+") { return DiffLine(kind: .added, text: String(line.dropFirst())) }
            if line.hasPrefix("-") { return DiffLine(kind: .removed, text: String(line.dropFirst())) }
            return DiffLine(kind: .context, text: line.hasPrefix(" ") ? String(line.dropFirst()) : line)
        }
    }
}

public struct DiffLine: Hashable, Codable, Sendable {
    public enum Kind: String, Hashable, Codable, Sendable {
        case context
        case added
        case removed
    }

    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    public var marker: String {
        switch kind {
        case .context: " "
        case .added: "+"
        case .removed: "−"
        }
    }
}

extension Array where Element == FileDiff {
    public var stat: DiffStat {
        DiffStat(
            files: count,
            additions: reduce(0) { $0 + $1.additions },
            deletions: reduce(0) { $0 + $1.deletions }
        )
    }
}

public struct CommitSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: String { hash }
    public var hash: String
    public var subject: String
    public var author: String
    public var date: Date
    public var isPushed: Bool
    /// Empty in a commit list; filled when one commit's diff is fetched.
    public var files: [FileDiff]

    public init(hash: String, subject: String, author: String, date: Date, isPushed: Bool, files: [FileDiff] = []) {
        self.hash = hash
        self.subject = subject
        self.author = author
        self.date = date
        self.isPushed = isPushed
        self.files = files
    }

    public var shortHash: String { String(hash.prefix(7)) }
}
