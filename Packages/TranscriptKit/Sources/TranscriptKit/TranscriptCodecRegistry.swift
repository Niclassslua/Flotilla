import Foundation
import SessionKit

/// Which agents can be handed off *from*, and which can be handed off *to*.
///
/// The two questions have different answers, so the registry keeps two tables
/// rather than one. Callers ask it rather than consulting a list of agent
/// kinds, which is what keeps "Antigravity cannot be a destination" a fact
/// about the codecs that exist instead of a condition someone has to remember
/// to write into the menu.
public struct TranscriptCodecRegistry: Sendable {
    private let readers: [AgentKind: any TranscriptReading]
    private let writers: [AgentKind: any TranscriptWriting]

    public init(
        readers: [any TranscriptReading] = [],
        writers: [any TranscriptWriting] = []
    ) {
        self.readers = Dictionary(uniqueKeysWithValues: readers.map { ($0.agent, $0) })
        self.writers = Dictionary(uniqueKeysWithValues: writers.map { ($0.agent, $0) })
    }

    /// The codecs Flotilla ships with.
    ///
    /// Antigravity is both a source and a target — see
    /// `AntigravityTranscriptCodec`'s doc comment and `FORMAT.md` alongside it
    /// for how an undocumented, reverse-engineered format backs both
    /// directions. OpenCode is absent from `readers` pending its HTTP session
    /// API.
    public static let `default` = TranscriptCodecRegistry(
        readers: [ClaudeTranscriptCodec(), CodexTranscriptCodec(), AntigravityTranscriptCodec()],
        writers: [ClaudeTranscriptCodec(), CodexTranscriptCodec(), AntigravityTranscriptCodec()]
    )

    public func reader(for agent: AgentKind) -> (any TranscriptReading)? {
        readers[agent]
    }

    public func writer(for agent: AgentKind) -> (any TranscriptWriting)? {
        writers[agent]
    }

    /// Agents a session can be moved away from.
    public var readableAgents: Set<AgentKind> { Set(readers.keys) }

    /// Agents a session can be moved to.
    public var writableAgents: Set<AgentKind> { Set(writers.keys) }

    /// The destinations offered for a session currently on `agent`.
    ///
    /// Excludes `agent` itself: moving a session to the agent already running
    /// it is a restart, and the app has one of those already.
    public func handoffTargets(from agent: AgentKind) -> [AgentKind] {
        guard readers[agent] != nil else { return [] }
        return AgentKind.allCases
            .filter { $0 != agent && writers[$0] != nil }
    }
}
