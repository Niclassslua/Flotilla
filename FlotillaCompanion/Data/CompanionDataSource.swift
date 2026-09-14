import Foundation
import SessionKit

/// Everything the companion reads from, and asks of, the paired Macs.
///
/// The seam where the prototype's simulated data is swapped for the real link:
/// views never see an implementation, only `CompanionStore`, which holds one of
/// these. Reads are synchronous snapshots of observable state; intents are
/// async because on the real link each is a round trip to the Mac.
@MainActor
protocol CompanionDataSource: AnyObject, Observable {
    var macs: [MacHost] { get }

    func sessions(on macID: MacHost.ID) -> [CompanionSession]
    func projects(on macID: MacHost.ID) -> [ProjectSummary]
    func catalog(on macID: MacHost.ID) -> AgentCatalog
    func session(_ id: CompanionSession.ID) -> CompanionSession?
    func macID(for sessionID: CompanionSession.ID) -> MacHost.ID?
    func transcript(for sessionID: CompanionSession.ID) -> SessionTranscript
    func pendingInteractions(for sessionID: CompanionSession.ID) -> [PendingInteraction]
    func diff(for sessionID: CompanionSession.ID) -> [FileDiff]
    func commits(for sessionID: CompanionSession.ID) -> [CommitSummary]
    func fileContents(at path: String, in sessionID: CompanionSession.ID) -> String?

    /// First answer wins: returns `.alreadyAnswered` when the Mac got there first.
    func answer(
        _ interactionID: PendingInteraction.ID,
        in sessionID: CompanionSession.ID,
        with answer: InteractionAnswer
    ) async -> AnswerOutcome
    func sendPrompt(_ text: String, to sessionID: CompanionSession.ID) async
    func stop(_ sessionID: CompanionSession.ID) async
    func createSession(_ request: NewSessionRequest, on macID: MacHost.ID) async -> CompanionSession.ID
    func handoff(_ sessionID: CompanionSession.ID, _ request: HandoffRequest) async
    func restart(_ sessionID: CompanionSession.ID) async
    func delete(_ sessionID: CompanionSession.ID, removeWorktree: Bool) async
    /// The diff was opened or a prompt sent; collapses the Ready-for-review card.
    func acknowledgeReview(_ sessionID: CompanionSession.ID)
}
