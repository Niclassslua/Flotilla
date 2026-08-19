import Foundation

/// A ref pointing at a commit, parsed from `git log --decorate=full`.
///
/// The *full* ref path (`refs/heads/…`) is deliberate: git's short `%D` form
/// is ambiguous, because a local branch may itself contain a slash. This repo
/// has `fix/tmux-status-line`, which the usual "contains a slash ⇒ remote"
/// heuristic would misclassify. Full paths make the distinction exact without
/// needing a second `git remote` call.
public struct GitCommitRef: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case head
        case localBranch
        case remoteBranch
        case tag
    }

    public var name: String
    public var kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }
}

/// One entry of `git log`, carrying enough for a history row to render
/// without any follow-up command — subject, identity, decoration, and the
/// aggregate line counts. `GitService.log` obtains all of it in a single
/// invocation, so a 100-commit page costs exactly one subprocess.
public struct GitCommit: Equatable, Sendable, Identifiable {
    public var sha: String
    public var shortSHA: String
    public var parents: [String]
    public var authorName: String
    public var authorEmail: String
    public var authorDate: Date
    public var committerName: String
    public var committerEmail: String
    public var committerDate: Date
    public var refs: [GitCommitRef]
    public var subject: String
    public var body: String

    /// Git trailers from the message's final block, keyed by lowercased name
    /// (`flotilla-agent`, `co-authored-by`, …). Parsed once here rather than
    /// on each access, since a history row reads them per render.
    public var trailers: [String: String]

    /// Aggregate line counts across the commit's files. Zero for merges:
    /// plain `git log --numstat` emits no stat block for them.
    public var stat: GitDiffStat
    public var changedFileCount: Int

    public var id: String { sha }
    public var isMerge: Bool { parents.count > 1 }

    /// True when the author and committer differ — a rebase, an amend by
    /// someone else, or a patch applied on another's behalf. Surfacing this
    /// only when it's true keeps the common case uncluttered.
    public var hasDistinctCommitter: Bool {
        authorEmail != committerEmail || authorName != committerName
    }

    public init(
        sha: String,
        shortSHA: String,
        parents: [String],
        authorName: String,
        authorEmail: String,
        authorDate: Date,
        committerName: String,
        committerEmail: String,
        committerDate: Date,
        refs: [GitCommitRef],
        subject: String,
        body: String,
        trailers: [String: String] = [:],
        stat: GitDiffStat,
        changedFileCount: Int
    ) {
        self.sha = sha
        self.shortSHA = shortSHA
        self.parents = parents
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorDate = authorDate
        self.committerName = committerName
        self.committerEmail = committerEmail
        self.committerDate = committerDate
        self.refs = refs
        self.subject = subject
        self.body = body
        self.trailers = trailers
        self.stat = stat
        self.changedFileCount = changedFileCount
    }
}

/// A single file touched by a commit. `hunks` reuses `FileDiffHunk` so the
/// commit detail view can render the same diff shape the live diff panel
/// produces.
public struct GitCommitFileChange: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case added
        case modified
        case deleted
        case renamed
        case copied
        case typeChanged
        case unmerged
    }

    public var path: String
    /// Set only for renames and copies — the path the content came from.
    public var previousPath: String?
    public var kind: Kind
    public var hunks: [FileDiffHunk]

    public var id: String { path }

    /// Counted from the hunk lines rather than taken from `--numstat`,
    /// because numstat renders a rename as the single fused path
    /// `old => new`, which cannot be matched back to the `--name-status`
    /// entry it belongs to. Counting the patch sidesteps that entirely.
    /// Binary files carry no hunks and therefore report zero, matching how
    /// numstat reports them as `-`.
    public var stat: GitDiffStat {
        var additions = 0
        var deletions = 0
        for line in hunks.flatMap(\.lines) {
            if line.hasPrefix("+") {
                additions += 1
            } else if line.hasPrefix("-") {
                deletions += 1
            }
        }
        return GitDiffStat(additions: additions, deletions: deletions)
    }

    public init(path: String, previousPath: String? = nil, kind: Kind, hunks: [FileDiffHunk] = []) {
        self.path = path
        self.previousPath = previousPath
        self.kind = kind
        self.hunks = hunks
    }
}

/// A commit plus the files it touched. Merges legitimately come back with an
/// empty `files`: `git show` reports no changes for a merge unless asked to
/// diff against a specific parent, and the UI says so rather than pretending
/// the commit was empty.
public struct GitCommitDetail: Equatable, Sendable {
    public var commit: GitCommit
    public var files: [GitCommitFileChange]

    public init(commit: GitCommit, files: [GitCommitFileChange]) {
        self.commit = commit
        self.files = files
    }

    public var stat: GitDiffStat {
        files.reduce(GitDiffStat(additions: 0, deletions: 0)) { $0 + $1.stat }
    }
}

// MARK: - Parsing

public extension GitService {
    /// ASCII record/unit separators. Chosen over any printable delimiter
    /// because they cannot occur in a commit subject or body, so no amount of
    /// creative commit prose can desynchronize the parse.
    static let logRecordSeparator: Character = "\u{1e}"
    static let logUnitSeparator: Character = "\u{1f}"

    /// Field order matters: `%b` is free-form and goes last, so the trailing
    /// split lands body *and* the `--numstat` block in one component that
    /// `splitBodyAndNumstat` then separates. Timestamps are `%at`/`%ct`
    /// (epoch seconds) rather than `%aI`, which removes ISO-8601 parsing and
    /// its timezone-offset edge cases from the hot path entirely.
    static let logFormat =
        "%x1e%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ce%x1f%ct%x1f%D%x1f%s%x1f%b"

    /// Number of fields `logFormat` produces. The split uses `maxSplits` of
    /// one less, so a body containing a stray unit separator can't shift
    /// every subsequent field.
    static var logFieldCount: Int { 12 }

    /// `public` for the same direct-unit-testability reason as
    /// `parseUnifiedDiff`: exercising multi-line bodies, merges, and missing
    /// stat blocks through a real repo would make the edge cases laborious to
    /// set up precisely.
    static func parseLog(_ raw: String) -> [GitCommit] {
        raw.split(separator: logRecordSeparator, omittingEmptySubsequences: true)
            .compactMap { parseLogRecord(String($0)) }
    }

    private static func parseLogRecord(_ record: String) -> GitCommit? {
        let fields = record
            .split(
                separator: logUnitSeparator,
                maxSplits: logFieldCount - 1,
                omittingEmptySubsequences: false
            )
            .map(String.init)
        guard fields.count == logFieldCount else { return nil }
        guard !fields[0].isEmpty,
              let authorSeconds = TimeInterval(fields[5]),
              let committerSeconds = TimeInterval(fields[8]) else { return nil }

        let (body, stat, fileCount) = splitBodyAndNumstat(fields[11])
        return GitCommit(
            sha: fields[0],
            shortSHA: fields[1],
            parents: fields[2].split(separator: " ").map(String.init),
            authorName: fields[3],
            authorEmail: fields[4],
            authorDate: Date(timeIntervalSince1970: authorSeconds),
            committerName: fields[6],
            committerEmail: fields[7],
            committerDate: Date(timeIntervalSince1970: committerSeconds),
            refs: parseRefs(fields[9]),
            subject: fields[10],
            body: body,
            trailers: parseTrailers(body),
            stat: stat,
            changedFileCount: fileCount
        )
    }

    /// Separates the commit body from the `--numstat` block git appends after
    /// it. Scans from the *end* because the stat block is always last — a
    /// body line that happens to look like a numstat entry therefore cannot
    /// swallow the real block, only be mistaken for part of it, which is the
    /// far rarer and less damaging direction to be wrong in.
    static func splitBodyAndNumstat(_ tail: String) -> (body: String, stat: GitDiffStat, fileCount: Int) {
        var lines = tail.components(separatedBy: "\n")
        while lines.last?.isEmpty == true { lines.removeLast() }

        var numstat: [String] = []
        while let last = lines.last, isNumstatLine(last) {
            numstat.append(last)
            lines.removeLast()
        }
        while lines.last?.isEmpty == true { lines.removeLast() }

        let block = numstat.joined(separator: "\n")
        return (
            body: lines.joined(separator: "\n"),
            stat: parseNumstat(block),
            fileCount: numstat.count
        )
    }

    /// `added<TAB>deleted<TAB>path`, where either count may be `-` for a
    /// binary file.
    private static func isNumstatLine(_ line: String) -> Bool {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 3, !fields[2].isEmpty else { return false }
        let countsParse = { (field: Substring) in Int(field) != nil || field == "-" }
        return countsParse(fields[0]) && countsParse(fields[1])
    }

    /// Parses git trailers — the `Key: value` lines in a message's final
    /// block. Scans backwards from the end and stops at the first line that
    /// isn't one, which is what keeps a `Note: see foo` sentence in the middle
    /// of a paragraph from being mistaken for a trailer.
    ///
    /// Keys are lowercased so lookups don't have to guess the casing an agent
    /// wrote.
    static func parseTrailers(_ body: String) -> [String: String] {
        var trailers: [String: String] = [:]
        for rawLine in body.components(separatedBy: "\n").reversed() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                // A blank line closes the trailer block; anything above it is
                // prose. Keep scanning only if nothing has been found yet, so
                // a message ending in blank lines still parses.
                if trailers.isEmpty { continue }
                break
            }
            guard let colon = line.firstIndex(of: ":") else { break }
            let key = String(line[line.startIndex..<colon])
            guard isTrailerKey(key) else { break }
            trailers[key.lowercased()] = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }
        return trailers
    }

    /// Git's own rule: alphanumerics and hyphens, starting with a letter.
    private static func isTrailerKey(_ key: String) -> Bool {
        guard let first = key.first, first.isLetter else { return false }
        return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// Parses `%D` under `--decorate=full`, e.g.
    /// `HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1.0`.
    static func parseRefs(_ raw: String) -> [GitCommitRef] {
        guard !raw.isEmpty else { return [] }
        var refs: [GitCommitRef] = []

        for piece in raw.components(separatedBy: ",") {
            var token = piece.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { continue }

            // `HEAD -> refs/heads/main` names two things at once.
            if let arrow = token.range(of: " -> ") {
                refs.append(GitCommitRef(name: "HEAD", kind: .head))
                token = String(token[arrow.upperBound...])
            }

            var isTag = false
            if token.hasPrefix("tag: ") {
                isTag = true
                token = String(token.dropFirst("tag: ".count))
            }

            if token.hasPrefix("refs/tags/") {
                refs.append(GitCommitRef(name: String(token.dropFirst("refs/tags/".count)), kind: .tag))
            } else if token.hasPrefix("refs/heads/") {
                refs.append(GitCommitRef(name: String(token.dropFirst("refs/heads/".count)), kind: .localBranch))
            } else if token.hasPrefix("refs/remotes/") {
                refs.append(GitCommitRef(name: String(token.dropFirst("refs/remotes/".count)), kind: .remoteBranch))
            } else if token == "HEAD" {
                refs.append(GitCommitRef(name: "HEAD", kind: .head))
            } else if !token.isEmpty {
                refs.append(GitCommitRef(name: token, kind: isTag ? .tag : .localBranch))
            }
        }
        return refs
    }

    /// Parses `git show --name-status --find-renames`: `M<TAB>path` for
    /// ordinary changes, `R100<TAB>old<TAB>new` for renames and copies (the
    /// digits are a similarity score, not part of the status).
    static func parseNameStatus(_ raw: String) -> [GitCommitFileChange] {
        raw.split(separator: "\n", omittingEmptySubsequences: true).compactMap { rawLine in
            let fields = rawLine.split(separator: "\t", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 2, let marker = fields[0].first else { return nil }

            switch marker {
            case "A": return GitCommitFileChange(path: fields[1], kind: .added)
            case "D": return GitCommitFileChange(path: fields[1], kind: .deleted)
            case "M": return GitCommitFileChange(path: fields[1], kind: .modified)
            case "T": return GitCommitFileChange(path: fields[1], kind: .typeChanged)
            case "U": return GitCommitFileChange(path: fields[1], kind: .unmerged)
            case "R", "C":
                guard fields.count >= 3 else { return nil }
                return GitCommitFileChange(
                    path: fields[2],
                    previousPath: fields[1],
                    kind: marker == "R" ? .renamed : .copied
                )
            default: return nil
            }
        }
    }

    /// Turns a git remote into a browsable commit URL, handling the three
    /// shapes a remote realistically takes: `git@host:owner/repo.git`,
    /// `ssh://git@host/owner/repo.git`, and `https://host/owner/repo.git`.
    /// Returns `nil` for anything else (a local path remote, say) so callers
    /// can simply hide the affordance.
    ///
    /// `public static` and pure, so remote-shape coverage needs no repo.
    static func webURL(forRemote remote: String, commitSHA: String) -> URL? {
        var trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !commitSHA.isEmpty else { return nil }

        if trimmed.hasPrefix("ssh://") {
            trimmed = String(trimmed.dropFirst("ssh://".count))
        }
        // `git@host:owner/repo` — the colon is a path separator here, not a
        // port, so it has to become a slash before this can be a URL.
        if !trimmed.contains("://"), let colon = trimmed.firstIndex(of: ":") {
            trimmed = trimmed.replacingCharacters(in: colon...colon, with: "/")
        }
        if let at = trimmed.firstIndex(of: "@"), !trimmed.contains("://") {
            trimmed = String(trimmed[trimmed.index(after: at)...])
        }
        if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") {
            guard let host = URL(string: trimmed)?.host else { return nil }
            trimmed = host + URL(string: trimmed)!.path
        }
        if trimmed.hasSuffix(".git") {
            trimmed = String(trimmed.dropLast(".git".count))
        }
        while trimmed.hasSuffix("/") { trimmed = String(trimmed.dropLast()) }

        // A filesystem path is a perfectly valid git remote but has no web
        // presence, so it must not be dressed up as one.
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix(".") else { return nil }

        // Needs at least host/owner/repo, and a host is only a host if it's
        // dotted — this is what rejects `file://` and bare local paths.
        let components = trimmed.split(separator: "/")
        guard components.count >= 3, components[0].contains(".") else { return nil }
        return URL(string: "https://\(trimmed)/commit/\(commitSHA)")
    }
}
