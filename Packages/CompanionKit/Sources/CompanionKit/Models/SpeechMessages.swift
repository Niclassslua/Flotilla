import Foundation

/// Audio remains inside the existing encrypted Companion session.
public struct CompanionSpeechStart: Hashable, Codable, Sendable {
    public let requestID: UUID
    public let mode: String
    public let languageHints: [String]
    public let verbatimTerms: [String]
    public let spokenCorrections: [CompanionSpeechCorrection]

    public init(requestID: UUID, mode: String = "live", languageHints: [String] = [],
                verbatimTerms: [String] = [], spokenCorrections: [CompanionSpeechCorrection] = []) {
        self.requestID = requestID
        self.mode = mode
        self.languageHints = languageHints
        self.verbatimTerms = verbatimTerms
        self.spokenCorrections = spokenCorrections
    }
}

public struct CompanionSpeechCorrection: Hashable, Codable, Sendable {
    public let spoken: String
    public let written: String

    public init(spoken: String, written: String) {
        self.spoken = spoken
        self.written = written
    }
}

public enum CompanionSpeechEvent: Hashable, Codable, Sendable {
    case capabilities(status: String, models: [String])
    case started(requestID: UUID, modelID: String)
    case audioAck(requestID: UUID, nextSequence: Int)
    case slowDown(requestID: UUID, nextSequence: Int)
    case final(requestID: UUID, revision: UInt64, text: String)
    case cancelled(requestID: UUID)
    case failed(requestID: UUID?, code: String, message: String, retryable: Bool)
}
