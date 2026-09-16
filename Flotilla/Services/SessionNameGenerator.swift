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
        @Guide(description: "A concise, specific 2 to 5 word noun-phrase session title in sentence case. Keep code identifiers verbatim. No action verb, trailing action noun, colon, or explanation.")
        var title: String
    }

    func name(for goal: String) async -> String? {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case .available = SystemLanguageModel.default.availability else { return nil }

        do {
            let session = LanguageModelSession(instructions: "Name coding-agent sessions. Identify the most specific component, feature, file, function, service, error, or concept in the user's request. Respond with a short noun phrase, not a task description.")
            let response = try await session.respond(to: goal, generating: SuggestedName.self)
            return Self.validated(response.content.title)
        } catch {
            return nil
        }
    }

    static func validated(_ suggestion: String) -> String? {
        let title = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = title.split(whereSeparator: \.isWhitespace)
        guard (2...5).contains(words.count),
              title.count <= 60,
              !title.contains(where: \.isNewline),
              !title.contains(":"),
              !title.contains("—"),
              !title.contains("–"),
              title.range(of: "[A-Za-z0-9]", options: .regularExpression) != nil else { return nil }
        return title
    }
}
