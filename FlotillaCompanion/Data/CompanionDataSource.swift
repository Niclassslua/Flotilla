import Foundation
import SessionKit
import CompanionKit

/// Everything the companion reads from, and asks of, the paired Macs.
///
/// Two implementations: `RemoteCompanionDataSource` talks to real Macs, and
/// `MockCompanionDataSource` runs the demo fleet (`-demo`). Views never see
/// either; they talk to `CompanionStore`. Reads are synchronous snapshots of
/// observable state; intents are async round trips that throw
/// `CompanionActionError` with a message worth showing.
@MainActor
protocol CompanionDataSource: AnyObject, Observable {
    /// Monotonically increases when remote state changes inside a data source.
    ///
    /// The remote source owns observable `MacConnection` children. SwiftUI
    /// must observe this forwarding token because replacing a child's fleet
    /// does not mutate the parent's `connections` array.
    var observationRevision: UInt64 { get }
    var macs: [MacHost] { get }
    /// `false` for the demo, which has nothing to pair with.
    var supportsPairing: Bool { get }

    func sessions(on macID: MacHost.ID) -> [CompanionSession]
    func projects(on macID: MacHost.ID) -> [ProjectSummary]
    func catalog(on macID: MacHost.ID) -> AgentCatalog
    func session(_ id: CompanionSession.ID) -> CompanionSession?
    func macID(for sessionID: CompanionSession.ID) -> MacHost.ID?
    func transcript(for sessionID: CompanionSession.ID) -> SessionTranscript
    func pendingInteractions(for sessionID: CompanionSession.ID) -> [PendingInteraction]

    /// When the phone received the fleet/transcript it's currently showing
    /// for this Mac/session — `nil` for a legacy cache with no such record,
    /// which reads as an unknown time, never as live.
    func fleetReceivedAt(_ macID: MacHost.ID) -> Date?
    func transcriptReceivedAt(_ sessionID: CompanionSession.ID) -> Date?

    func diff(for sessionID: CompanionSession.ID, commitHash: String?) -> Remote<[FileDiff]>
    func commits(for sessionID: CompanionSession.ID) -> Remote<[CommitSummary]>
    func fileContents(at path: String, in sessionID: CompanionSession.ID) -> Remote<String?>
    func loadDiff(for sessionID: CompanionSession.ID, commitHash: String?) async
    func loadCommits(for sessionID: CompanionSession.ID) async
    func loadFile(at path: String, in sessionID: CompanionSession.ID) async

    /// The session on screen, whose transcript should stay live.
    func focus(on sessionID: CompanionSession.ID?)
    /// App foreground / background.
    func setActive(_ isActive: Bool)

    /// First answer wins: returns `.alreadyAnswered` when the Mac got there first.
    func answer(
        _ interactionID: PendingInteraction.ID,
        in sessionID: CompanionSession.ID,
        with answer: InteractionAnswer
    ) async throws -> AnswerOutcome
    func sendPrompt(_ text: String, to sessionID: CompanionSession.ID) async throws
    func stop(_ sessionID: CompanionSession.ID) async throws
    func isSpeechAvailable(on macID: MacHost.ID) -> Bool
    func speech(_ message: ClientMessage, on macID: MacHost.ID) async throws -> CompanionSpeechEvent
    func createSession(_ request: NewSessionRequest, on macID: MacHost.ID) async throws -> CompanionSession.ID
    func handoff(_ sessionID: CompanionSession.ID, _ request: HandoffRequest) async throws
    func restart(_ sessionID: CompanionSession.ID) async throws
    func delete(_ sessionID: CompanionSession.ID, removeWorktree: Bool) async throws
    /// The diff was opened or a prompt sent; collapses the Ready-for-review card.
    func acknowledgeReview(_ sessionID: CompanionSession.ID)

    /// Pairs with the Mac in `payload`, reporting each connection attempt.
    func pair(with payload: PairingPayload, progress: @escaping @MainActor (ConnectTarget, AttemptStatus) -> Void) async throws -> MacHost.ID
    func removeMac(_ macID: MacHost.ID)
    func reconnect(_ macID: MacHost.ID)
    func clearCachedTranscripts(on macID: MacHost.ID)
    func clearAllCachedTranscripts()
}

struct CompanionActionError: LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }

    static let unreachable = CompanionActionError(message: "The Mac is unreachable.")
}
