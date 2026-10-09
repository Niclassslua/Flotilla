import Foundation
import SessionKit

/// Registry and convenience facade for accessing agent session providers.
public struct AgentSessionProviderRegistry: Sendable {
    public static let `default` = AgentSessionProviderRegistry()

    public let claudeProvider: ClaudeSessionProvider
    public let openCodeProvider: OpenCodeSessionProvider
    public let codexProvider: CodexSessionProvider
    public let antigravityProvider: ExperimentalAntigravitySessionProvider
    public let cursorProvider: CursorSessionProvider

    public init(
        claudeProvider: ClaudeSessionProvider = ClaudeSessionProvider(),
        openCodeProvider: OpenCodeSessionProvider = OpenCodeSessionProvider(),
        codexProvider: CodexSessionProvider = CodexSessionProvider(),
        antigravityProvider: ExperimentalAntigravitySessionProvider = ExperimentalAntigravitySessionProvider(),
        cursorProvider: CursorSessionProvider = CursorSessionProvider()
    ) {
        self.claudeProvider = claudeProvider
        self.openCodeProvider = openCodeProvider
        self.codexProvider = codexProvider
        self.antigravityProvider = antigravityProvider
        self.cursorProvider = cursorProvider
    }

    public func provider(for kind: AgentKind) -> any AgentSessionProviding {
        switch kind {
        case .claudeCode:
            return claudeProvider
        case .openCode:
            return openCodeProvider
        case .codexCLI:
            return codexProvider
        case .antigravity:
            return antigravityProvider
        case .cursorAgent:
            return cursorProvider
        }
    }

    /// Resolves the latest native session and title for a specific agent running in `workingDirectory`,
    /// filtered by minimum modification date (`since`).
    public func fetchLatestSession(
        for kind: AgentKind,
        workingDirectory: URL,
        since: Date? = nil
    ) async -> DiscoveredAgentSession? {
        let provider = self.provider(for: kind)
        return try? await provider.fetchLatestSession(for: workingDirectory, since: since)
    }
}
