import Foundation
import FoundationModels

@MainActor
protocol SessionNameGenerating {
    /// Returns nil when on-device generation is unavailable or unsuitable.
    func name(for goal: String) async -> String?
}

/// Generates a typed response rather than asking a model to print parseable JSON.
/// Foundation Models guided generation is available from macOS 26 onward.
@MainActor
struct AppleIntelligenceSessionNameGenerator: SessionNameGenerating {
    @Generable
    struct SuggestedName {
        @Guide(description: "A concise, specific 2 to 5 word noun-phrase session title in sentence case (capitalize the first word; leave the rest lowercase unless a proper noun or code identifier). Keep code identifiers verbatim. No action verb, trailing action noun, colon, or explanation.")
        var title: String
    }

    /// Kept free of noun phrases the model could echo back as a title.
    /// Explicitly asks for sentence case — without that, on-device models often
    /// return all-lowercase phrases that show up as session names in the UI.
    nonisolated static let instructions = """
        Title this session from the user's request only. Pick the most specific \
        component, feature, file, function, service, error, or concept named in \
        that request. Reply with a short noun phrase in sentence case — capitalize \
        the first word, keep code identifiers' original casing. Never a task \
        description, and never restate these instructions.
        """

    /// Phrases previously returned when the model parroted earlier instructions.
    nonisolated private static let rejectedTitles: Set<String> = [
        "coding-agent sessions",
        "coding agent sessions",
        "name coding-agent sessions",
        "name coding agent sessions",
    ]

    func name(for goal: String) async -> String? {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case .available = SystemLanguageModel.default.availability else { return nil }

        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let response = try await session.respond(to: goal, generating: SuggestedName.self)
            return Self.validated(response.content.title)
        } catch {
            return nil
        }
    }

    nonisolated static func validated(_ suggestion: String) -> String? {
        var title = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = title.split(whereSeparator: \.isWhitespace)
        guard (2...5).contains(words.count),
              title.count <= 60,
              !title.contains(where: \.isNewline),
              !title.contains(":"),
              !title.contains("—"),
              !title.contains("–"),
              title.range(of: "[A-Za-z0-9]", options: .regularExpression) != nil else { return nil }

        let normalized = title
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !Self.rejectedTitles.contains(normalized) else { return nil }

        // On-device models still return all-lowercase phrases despite the
        // sentence-case guide. Promote the first letter so session names read
        // as titles, while leaving mixed-case identifiers untouched.
        title = Self.applySentenceCaseIfNeeded(title)

        return title
    }

    /// Capitalizes the first letter only when the whole title is lowercase.
    /// Mixed-case and PascalCase/camelCase identifiers pass through unchanged.
    nonisolated static func applySentenceCaseIfNeeded(_ title: String) -> String {
        guard !title.isEmpty else { return title }
        let hasUppercase = title.contains(where: \.isUppercase)
        guard !hasUppercase, let first = title.first, first.isLetter else { return title }
        return String(first).uppercased() + title.dropFirst()
    }
}
