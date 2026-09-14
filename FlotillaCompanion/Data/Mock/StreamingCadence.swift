import Foundation
import SessionKit
import CompanionKit

/// Simulated live output at each provider's granularity.
extension MockCompanionDataSource {
    /// Grows the in-progress assistant message, then commits it.
    func streamReply(_ text: String, in sessionID: CompanionSession.ID) async throws {
        guard let agent = session(sessionID)?.agent else { return }
        switch ProviderCapabilities.of(agent).streaming {
        case .lines:
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            mutateTranscript(sessionID) { $0.streamingText = "" }
            for line in lines {
                try await pause(0.45)
                mutateTranscript(sessionID) { $0.streamingText = ($0.streamingText ?? "") + line + "\n" }
            }
        case .tokens:
            mutateTranscript(sessionID) { $0.streamingText = "" }
            for token in Self.tokens(in: text) {
                try await pause(0.035)
                mutateTranscript(sessionID) { $0.streamingText = ($0.streamingText ?? "") + token }
            }
        case .steps:
            try await pause(2)
        }
        try Task.checkCancellation()
        mutateTranscript(sessionID) {
            $0.streamingText = nil
            $0.append(.assistantMessage(text: text, timestamp: .now))
        }
    }

    /// Appends a tool call, waits, then its result.
    func runTool(
        _ tool: String,
        _ input: [String: String],
        output: String,
        isError: Bool = false,
        seconds: Double,
        in sessionID: CompanionSession.ID
    ) async throws {
        let useID = UUID().uuidString
        mutateTranscript(sessionID) { $0.append(.toolUse(id: useID, tool: tool, input: input, timestamp: .now)) }
        try await pause(seconds)
        mutateTranscript(sessionID) { $0.append(.toolResult(toolUseID: useID, output: output, isError: isError, timestamp: .now)) }
    }

    /// Word-ish chunks that keep their trailing whitespace, like model tokens.
    private static func tokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == " " || character == "\n" {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
