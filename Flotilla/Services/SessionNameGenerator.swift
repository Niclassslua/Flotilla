import Foundation
import FoundationModels
import os

@MainActor
protocol SessionNameGenerating {
    /// Returns nil when on-device generation is unavailable or unsuitable.
    func name(for goal: String) async -> String?
}

/// Generates a typed response rather than asking a model to print parseable JSON.
/// Foundation Models guided generation is available from macOS 26 onward.
///
/// Failures used to return silent `nil`, so a bad sidebar title could not be
/// traced. Every outcome is now logged under category `SessionNaming`:
///
///     log stream --style compact --predicate 'subsystem == "com.niclassslua.flotilla" AND category == "SessionNaming"'
@MainActor
struct AppleIntelligenceSessionNameGenerator: SessionNameGenerating {
    private static let logger = Logger(subsystem: "com.niclassslua.flotilla", category: "SessionNaming")

    @Generable
    struct SuggestedName {
        @Guide(description: "2 to 5 word noun-phrase title naming the subject. Sentence case (capitalize the first word; leave the rest lowercase unless a proper noun or code identifier). Keep code identifiers verbatim. No first person, colon, or explanation.")
        var title: String
    }

    /// Short on purpose. Longer "never restated these instructions" prompts made
    /// the on-device model collapse conversational goals into a one-word answer
    /// (`hooks`, `useCallback`) that validation rejected. This wording
    /// consistently yields multi-word subject titles like "Hooks documentation".
    /// Kept free of concrete example phrases the model could echo back.
    nonisolated static let instructions = """
        Extract a short session title from the request. Prefer the concrete \
        subject (feature, component, docs topic). Output a 2-5 word noun \
        phrase only.
        """

    /// Sent once in the same `LanguageModelSession` when the first suggestion
    /// fails validation — usually a one-word collapse on a chatty goal.
    nonisolated private static let retryPrompt = """
        Too short or unsuitable. Expand into a 2-5 word noun phrase naming \
        the topic — not a single word, not the user's request wording.
        """

    /// Phrases previously returned when the model parroted earlier instructions.
    nonisolated private static let rejectedTitles: Set<String> = [
        "coding-agent sessions",
        "coding agent sessions",
        "name coding-agent sessions",
        "name coding agent sessions",
    ]

    /// First-person / request-shaped openings that mean the model echoed the ask
    /// instead of naming the subject.
    nonisolated private static let requestShapedPattern = #"(?i)^(i|i'd|i'll|i'm|we|let's|please|can|could|would|help)\b"#

    func name(for goal: String) async -> String? {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else {
            Self.logger.notice("skipped — empty goal")
            return nil
        }

        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            Self.logger.notice("unavailable — \(String(describing: reason), privacy: .public)")
            return nil
        @unknown default:
            Self.logger.notice("unavailable — unknown availability")
            return nil
        }

        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let first = try await session.respond(to: trimmedGoal, generating: SuggestedName.self)
            if let title = Self.accept(first.content.title, against: trimmedGoal, attempt: "first") {
                return title
            }

            let second = try await session.respond(to: Self.retryPrompt, generating: SuggestedName.self)
            return Self.accept(second.content.title, against: trimmedGoal, attempt: "retry")
        } catch {
            Self.logger.error(
                "generation failed — \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Logs accept/reject and returns the cleaned title when valid.
    private static func accept(_ raw: String, against goal: String, attempt: String) -> String? {
        switch validate(raw, against: goal) {
        case .accepted(let title):
            logger.notice(
                "\(attempt, privacy: .public) accepted \"\(title, privacy: .public)\" (raw \"\(raw, privacy: .public)\")"
            )
            return title
        case .rejected(let suggestion, let reason):
            logger.notice(
                "\(attempt, privacy: .public) rejected \"\(suggestion, privacy: .public)\" — \(reason, privacy: .public)"
            )
            return nil
        }
    }

    nonisolated enum ValidationResult: Equatable {
        case accepted(String)
        case rejected(suggestion: String, reason: String)
    }

    /// Validates a model suggestion. When `goal` is provided, rejects titles that
    /// merely echo the start of the user's request (the failure mode that used
    /// to land full prompt sentences in the sidebar after a nil fallback).
    nonisolated static func validate(_ suggestion: String, against goal: String? = nil) -> ValidationResult {
        var title = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = title
        // Model sometimes returns a usable noun phrase buried in a longer line —
        // clip before the hard checks so "Hooks documentation for the fleet"
        // still becomes a title instead of falling back to the raw goal.
        let words = title.split(whereSeparator: \.isWhitespace)
        if words.count > 5 {
            title = words.prefix(5).joined(separator: " ")
        }

        let clippedWords = title.split(whereSeparator: \.isWhitespace)
        guard (2...5).contains(clippedWords.count) else {
            return .rejected(suggestion: original, reason: "need 2…5 words, got \(clippedWords.count)")
        }
        guard title.count <= 60 else {
            return .rejected(suggestion: original, reason: "longer than 60 characters")
        }
        guard !title.contains(where: \.isNewline),
              !title.contains(":"),
              !title.contains("—"),
              !title.contains("–") else {
            return .rejected(suggestion: original, reason: "contains forbidden punctuation")
        }
        guard title.range(of: "[A-Za-z0-9]", options: .regularExpression) != nil else {
            return .rejected(suggestion: original, reason: "no alphanumeric characters")
        }

        let normalized = title
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if Self.rejectedTitles.contains(normalized) {
            return .rejected(suggestion: original, reason: "known instruction echo")
        }
        if normalized.range(of: Self.requestShapedPattern, options: .regularExpression) != nil {
            return .rejected(suggestion: original, reason: "request-shaped phrasing")
        }

        if let goal {
            let goalNormalized = goal
                .lowercased()
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if goalNormalized.hasPrefix(normalized) {
                return .rejected(suggestion: original, reason: "echoes the start of the goal")
            }
        }

        // On-device models still return all-lowercase phrases despite the
        // sentence-case guide. Promote the first letter so session names read
        // as titles, while leaving mixed-case identifiers untouched.
        title = Self.applySentenceCaseIfNeeded(title)
        return .accepted(title)
    }

    nonisolated static func validated(_ suggestion: String, against goal: String? = nil) -> String? {
        if case .accepted(let title) = validate(suggestion, against: goal) {
            return title
        }
        return nil
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
