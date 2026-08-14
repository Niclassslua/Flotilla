import Foundation

public enum BranchNaming {
    /// Slugifies a session title into a git-safe branch name with a short
    /// unique suffix so two sessions with the same goal never collide.
    public static func generate(from title: String, uuid: UUID = UUID()) -> String {
        let slug = title
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let shortID = uuid.uuidString.prefix(8).lowercased()
        let base = slug.isEmpty ? "session" : slug
        return "flotilla/\(base)-\(shortID)"
    }
}
