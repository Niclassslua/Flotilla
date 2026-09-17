import Foundation

public enum BranchNaming {
    /// Keeps slugs (and therefore worktree directory names) short enough to
    /// stay readable and well under filesystem path limits even after the
    /// `flotilla/` prefix and `-<8hex>` suffix are added.
    private static let maxSlugLength = 30

    /// Slugifies a session title into a git-safe branch name with a short
    /// unique suffix so two sessions with the same goal never collide.
    public static func generate(from title: String, uuid: UUID = UUID()) -> String {
        let fullSlug = title
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let slug = truncate(fullSlug, to: maxSlugLength)
        let shortID = uuid.uuidString.prefix(8).lowercased()
        let base = slug.isEmpty ? "session" : slug
        return "flotilla/\(base)-\(shortID)"
    }

    /// Returns the human-readable form of a Flotilla-managed branch.
    ///
    /// The namespace and collision suffix are useful to Git, but add noise
    /// everywhere a session is represented in the UI. Keep the stored value
    /// unchanged and apply this only at presentation boundaries.
    public static func displayName(for branch: String) -> String {
        let isFlotillaBranch = branch.hasPrefix("flotilla/")
        var name = isFlotillaBranch ? String(branch.dropFirst("flotilla/".count)) : branch

        guard isFlotillaBranch,
              let separator = name.lastIndex(of: "-"),
              name.distance(from: separator, to: name.endIndex) == 9
        else { return name }

        let suffix = name[name.index(after: separator)...]
        guard suffix.allSatisfy({ $0.isHexDigit }) else { return name }
        name.removeSubrange(separator..<name.endIndex)
        return name.isEmpty ? branch : name
    }

    /// Truncates to at most `limit` characters, preferring to cut at a
    /// `-` boundary so words aren't chopped mid-way, then drops any
    /// trailing dash left by the cut.
    private static func truncate(_ slug: String, to limit: Int) -> String {
        guard slug.count > limit else { return slug }
        let cutoff = slug.index(slug.startIndex, offsetBy: limit)
        let truncated = slug[slug.startIndex..<cutoff]
        if let lastDash = truncated.lastIndex(of: "-"), lastDash != truncated.startIndex {
            return String(truncated[truncated.startIndex..<lastDash])
        }
        return truncated.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
