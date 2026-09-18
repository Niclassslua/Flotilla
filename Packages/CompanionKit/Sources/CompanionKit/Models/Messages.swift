import Foundation
import SessionKit

/// The wire protocol version. Both the handshake and the pairing link carry it.
public enum CompanionProtocol {
    public static let version = 4
    /// Transcripts are capped to the newest events (docs/companion.md, A7).
    public static let transcriptEventLimit = 400
}

/// Sent by the phone inside the encrypted channel.
public enum ClientMessage: Hashable, Codable, Sendable {
    /// Start receiving `transcript` and `pending` for one session; replaces any
    /// earlier subscription.
    case subscribe(sessionID: UUID)
    case resyncTranscript(sessionID: UUID)
    case resyncFleet
    case unsubscribe
    case request(id: UInt64, CompanionRequest)
    case speechCapabilities
    case speechStart(CompanionSpeechStart)
    case speechAudio(requestID: UUID, sequence: Int, pcm: Data)
    case speechFinish(requestID: UUID)
    case speechCancel(requestID: UUID)
    case ping
}

public enum CompanionRequest: Hashable, Codable, Sendable {
    case sendPrompt(sessionID: UUID, text: String)
    case stop(sessionID: UUID)
    case answer(sessionID: UUID, interactionID: UUID, answer: InteractionAnswer)
    case createSession(NewSessionRequest)
    case handoff(sessionID: UUID, HandoffRequest)
    case restart(sessionID: UUID)
    case delete(sessionID: UUID, removeWorktree: Bool)
    case diff(sessionID: UUID, commitHash: String?)
    case commits(sessionID: UUID)
    case file(sessionID: UUID, path: String)
    /// Fetches a bounded UTF-8 page; the phone transparently follows pages.
    case filePage(sessionID: UUID, path: String, offset: Int, maxBytes: Int)
}

/// Sent by the Mac inside the encrypted channel.
public enum ServerMessage: Hashable, Codable, Sendable {
    case fleet(FleetSnapshot)
    case fleetDelta(FleetDelta)
    case transcript(sessionID: UUID, SessionTranscript)
    case transcriptSnapshot(sessionID: UUID, revision: UInt64, SessionTranscript)
    case transcriptDelta(sessionID: UUID, TranscriptDelta)
    case response(id: UInt64, CompanionResponse)
    case speech(CompanionSpeechEvent)
    case pong
    /// The Mac's current reachable addresses, sent whenever they change (e.g.
    /// Tailscale connects after pairing) so an already-paired phone learns a
    /// new path without re-scanning a pairing code.
    case addressUpdate(candidates: [HostCandidate])
    /// A status edge worth surfacing while the phone's encrypted link is open.
    case attention(SessionAttentionEvent)
}

public struct SessionAttentionEvent: Hashable, Codable, Sendable {
    public let sessionID: UUID
    public let title: String
    public let status: SessionStatus
    public let summary: String
    public let permissionID: UUID?

    public init(sessionID: UUID, title: String, status: SessionStatus, summary: String, permissionID: UUID? = nil) {
        self.sessionID = sessionID
        self.title = title
        self.status = status
        self.summary = summary
        self.permissionID = permissionID
    }
}

public enum CompanionResponse: Hashable, Codable, Sendable {
    case ok
    case failure(message: String)
    case answer(AnswerOutcome)
    case created(sessionID: UUID)
    case diff([FileDiff])
    case commits([CommitSummary])
    case file(contents: String?)
    case filePage(contents: String?, nextOffset: Int?, isComplete: Bool)
}

/// Encoding shared by every JSON frame, so both ends agree on dates.
public enum CompanionJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }
}
