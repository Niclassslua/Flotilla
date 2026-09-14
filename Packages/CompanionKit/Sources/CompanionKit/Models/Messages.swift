import Foundation

/// The wire protocol version. Both the handshake and the pairing link carry it.
public enum CompanionProtocol {
    public static let version = 1
    /// Transcripts are capped to the newest events (docs/companion.md, A7).
    public static let transcriptEventLimit = 400
}

/// Sent by the phone inside the encrypted channel.
public enum ClientMessage: Hashable, Codable, Sendable {
    /// Start receiving `transcript` and `pending` for one session; replaces any
    /// earlier subscription.
    case subscribe(sessionID: UUID)
    case unsubscribe
    case request(id: UInt64, CompanionRequest)
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
}

/// Sent by the Mac inside the encrypted channel.
public enum ServerMessage: Hashable, Codable, Sendable {
    case fleet(FleetSnapshot)
    case transcript(sessionID: UUID, SessionTranscript)
    case response(id: UInt64, CompanionResponse)
    case pong
}

public enum CompanionResponse: Hashable, Codable, Sendable {
    case ok
    case failure(message: String)
    case answer(AnswerOutcome)
    case created(sessionID: UUID)
    case diff([FileDiff])
    case commits([CommitSummary])
    case file(contents: String?)
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
