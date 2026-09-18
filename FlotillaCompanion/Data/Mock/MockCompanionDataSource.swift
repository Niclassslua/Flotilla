import Foundation
import Observation
import SessionKit
import CompanionKit

/// Simulated Macs for the UI prototype. Intents behave plausibly — a prompt
/// starts a turn that streams at the provider's granularity, an answer
/// continues the turn — so every screen can be exercised without a Mac.
@Observable
@MainActor
final class MockCompanionDataSource: CompanionDataSource {
    private(set) var observationRevision: UInt64 = 0
    var macs: [MacHost]
    var sessionsByMac: [MacHost.ID: [CompanionSession]]
    var projectsByMac: [MacHost.ID: [ProjectSummary]]
    var transcripts: [CompanionSession.ID: SessionTranscript]
    var pending: [CompanionSession.ID: [PendingInteraction]]
    var diffs: [CompanionSession.ID: [FileDiff]]
    var commitsBySession: [CompanionSession.ID: [CommitSummary]]
    var files: [String: String]

    /// How long Stop takes to land. Scenarios lengthen it.
    var stopDelay: Duration = .seconds(1.2)
    /// Interactions the Mac already answered whose retraction hasn't reached
    /// the phone yet — a phone answer to one of these arrives late.
    var answeredOnMacPendingRetraction: Set<PendingInteraction.ID> = []
    /// The running `toolUse` a permission gates, completed once allowed.
    var gatedToolCalls: [PendingInteraction.ID: (useID: String, output: String)] = [:]

    @ObservationIgnored private var turnTasks: [CompanionSession.ID: Task<Void, Never>] = [:]

    init(fixtures: MockFixtures = .standard()) {
        macs = fixtures.macs
        sessionsByMac = fixtures.sessionsByMac
        projectsByMac = fixtures.projectsByMac
        transcripts = fixtures.transcripts
        pending = fixtures.pending
        diffs = fixtures.diffs
        commitsBySession = fixtures.commits
        files = fixtures.files
        gatedToolCalls = fixtures.gatedToolCalls
    }

    // MARK: - Reads

    func sessions(on macID: MacHost.ID) -> [CompanionSession] {
        (sessionsByMac[macID] ?? []).map(Self.withDemoHandoffTargets)
    }

    /// Mirrors the Mac's codec matrix: Antigravity can't be written to, and
    /// OpenCode can't be read from.
    static func withDemoHandoffTargets(_ session: CompanionSession) -> CompanionSession {
        var session = session
        if session.handoffTargets.isEmpty, session.agent != .openCode {
            session.handoffTargets = AgentKind.allCases.filter { $0 != session.agent && $0 != .antigravity }
        }
        return session
    }

    func projects(on macID: MacHost.ID) -> [ProjectSummary] {
        projectsByMac[macID] ?? []
    }

    func catalog(on macID: MacHost.ID) -> AgentCatalog {
        .fallback
    }

    func session(_ id: CompanionSession.ID) -> CompanionSession? {
        sessionsByMac.values.lazy.flatMap { $0 }.first { $0.id == id }.map(Self.withDemoHandoffTargets)
    }

    func macID(for sessionID: CompanionSession.ID) -> MacHost.ID? {
        sessionsByMac.first { $0.value.contains { $0.id == sessionID } }?.key
    }

    func transcript(for sessionID: CompanionSession.ID) -> SessionTranscript {
        transcripts[sessionID] ?? SessionTranscript()
    }

    func pendingInteractions(for sessionID: CompanionSession.ID) -> [PendingInteraction] {
        pending[sessionID] ?? []
    }

    /// The demo has no real cache to be honest about — it never claims a
    /// snapshot time it doesn't have.
    func fleetReceivedAt(_ macID: MacHost.ID) -> Date? { nil }
    func transcriptReceivedAt(_ sessionID: CompanionSession.ID) -> Date? { nil }

    var supportsPairing: Bool { false }

    func diff(for sessionID: CompanionSession.ID, commitHash: String?) -> Remote<[FileDiff]> {
        if let commitHash {
            return .loaded(commitsBySession[sessionID]?.first { $0.hash == commitHash }?.files ?? [])
        }
        return .loaded(diffs[sessionID] ?? [])
    }

    func commits(for sessionID: CompanionSession.ID) -> Remote<[CommitSummary]> {
        .loaded(commitsBySession[sessionID] ?? [])
    }

    func fileContents(at path: String, in sessionID: CompanionSession.ID) -> Remote<String?> {
        .loaded(files[path])
    }

    func loadDiff(for sessionID: CompanionSession.ID, commitHash: String?) async {}
    func loadCommits(for sessionID: CompanionSession.ID) async {}
    func loadFile(at path: String, in sessionID: CompanionSession.ID) async {}
    func focus(on sessionID: CompanionSession.ID?) {}
    func setActive(_ isActive: Bool) {}

    func clearCachedTranscripts(on macID: MacHost.ID) {
        for session in sessionsByMac[macID] ?? [] { transcripts.removeValue(forKey: session.id) }
    }

    func clearAllCachedTranscripts() {
        transcripts.removeAll()
    }

    func pair(with payload: PairingPayload, progress: @escaping @MainActor (ConnectTarget, AttemptStatus) -> Void) async throws -> MacHost.ID {
        throw CompanionActionError(message: "The demo can't pair with a Mac. Launch the app without -demo.")
    }

    func removeMac(_ macID: MacHost.ID) {
        macs.removeAll { $0.id == macID }
    }

    func reconnect(_ macID: MacHost.ID) {
        guard let index = macs.firstIndex(where: { $0.id == macID }) else { return }
        if case .needsRepairing = macs[index].connection { return }
        macs[index].connection = .connecting
        Task {
            try? await Task.sleep(for: .seconds(0.6))
            self.setReachable(true, macID: macID)
        }
    }

    // MARK: - Intents

    func answer(
        _ interactionID: PendingInteraction.ID,
        in sessionID: CompanionSession.ID,
        with answer: InteractionAnswer
    ) async throws -> AnswerOutcome {
        guard var list = pending[sessionID], let index = list.firstIndex(where: { $0.id == interactionID }) else {
            return .alreadyAnswered
        }
        if answeredOnMacPendingRetraction.contains(interactionID) {
            list[index].resolution = .alreadyAnswered
            pending[sessionID] = list
            Task {
                try? await Task.sleep(for: .seconds(2))
                retract(interactionID, in: sessionID, outcome: "Allowed")
            }
            return .alreadyAnswered
        }

        let interaction = list.remove(at: index)
        pending[sessionID] = list
        let (text, positive) = Self.resolutionText(for: interaction, answer: answer)
        mutateTranscript(sessionID) { $0.append(.resolvedInteraction(text: text, isPositive: positive)) }
        refreshAttention(sessionID)

        switch answer {
        case .denyAndStop:
            cancelTurn(sessionID)
            pending[sessionID] = []
            finishGatedCall(for: interaction.id, in: sessionID, output: "Denied by user", isError: true)
            mutateTranscript(sessionID) { $0.append(.systemNote(text: "Turn stopped", timestamp: .now)) }
            mutateSession(sessionID) { $0.status = .readyForReview; $0.waitingReason = nil; $0.attentionSummary = nil }
        case .revisePlan(let message):
            mutateTranscript(sessionID) { $0.append(.userMessage(text: message, timestamp: .now)) }
            if case .plan(let plan) = interaction.kind {
                startTurn(sessionID) { source in
                    try await source.pause(2)
                    try await source.streamReply("Revising the plan with that in mind.", in: sessionID)
                    try await source.pause(1)
                    source.raise(
                        PendingInteraction(kind: .plan(PlanProposal(title: plan.title + " (revised)", markdown: plan.markdown + "\n\n## Revision\n\n- \(message)"))),
                        in: sessionID
                    )
                }
            }
        case .deny, .denyWithNote:
            finishGatedCall(for: interaction.id, in: sessionID, output: "Denied by user", isError: true)
            if case .denyWithNote(let note) = answer {
                mutateTranscript(sessionID) { $0.append(.userMessage(text: note, timestamp: .now)) }
            }
            continueIfUnblocked(sessionID, reply: "Understood — I'll leave that alone and take a different route.")
        default:
            if case .allowWithNote(let note) = answer {
                mutateTranscript(sessionID) { $0.append(.userMessage(text: note, timestamp: .now)) }
            }
            finishGatedCall(for: interaction.id, in: sessionID, output: "Done", isError: false)
            continueIfUnblocked(sessionID, reply: "Thanks. Continuing — that step went through, and the remaining changes are in place.")
        }
        return .accepted
    }

    func sendPrompt(_ text: String, to sessionID: CompanionSession.ID) async throws {
        acknowledgeReview(sessionID)
        guard let session = session(sessionID) else { return }
        if session.status == .working {
            mutateTranscript(sessionID) { $0.queuedPrompts.append(QueuedPrompt(text: text, sentAt: .now)) }
            return
        }
        mutateTranscript(sessionID) { $0.append(.userMessage(text: text, timestamp: .now)) }
        mutateSession(sessionID) { $0.failure = nil }
        startReplyTurn(sessionID)
    }

    func stop(_ sessionID: CompanionSession.ID) async throws {
        mutateTranscript(sessionID) { $0.isStopping = true }
        try? await Task.sleep(for: stopDelay)
        cancelTurn(sessionID)
        mutateTranscript(sessionID) {
            $0.isStopping = false
            $0.streamingText = nil
            $0.retryAttempt = nil
            $0.append(.systemNote(text: "Interrupted", timestamp: .now))
        }
        mutateSession(sessionID) { $0.status = .readyForReview }
    }

    func isSpeechAvailable(on macID: MacHost.ID) -> Bool {
        true
    }

    func speech(_ message: ClientMessage, on macID: MacHost.ID) async throws -> CompanionSpeechEvent {
        switch message {
        case .speechCapabilities:
            .capabilities(status: "ready", models: ["Demo local model"])
        case let .speechStart(request):
            .started(requestID: request.requestID, modelID: "Demo local model")
        case let .speechAudio(requestID, sequence, _):
            .audioAck(requestID: requestID, nextSequence: sequence + 1)
        case let .speechFinish(requestID):
            .final(requestID: requestID, revision: 1, text: "Demo dictated text")
        case let .speechCancel(requestID):
            .cancelled(requestID: requestID)
        default:
            .failed(requestID: nil, code: "invalidRequest", message: "Unsupported demo request.", retryable: false)
        }
    }

    func createSession(_ request: NewSessionRequest, on macID: MacHost.ID) async throws -> CompanionSession.ID {
        let title = Self.title(from: request.goal)
        let session = CompanionSession(
            id: UUID(),
            title: title,
            agent: request.agent,
            model: request.model,
            effort: request.effort,
            status: .working,
            projectID: request.projectID,
            branch: request.createWorktree ? "flotilla/" + Self.slug(from: title) : nil,
            hasWorktree: request.createWorktree,
            isProcessLive: true,
            updatedAt: .now
        )
        sessionsByMac[macID, default: []].insert(session, at: 0)
        observationRevision &+= 1
        var transcript = SessionTranscript()
        if !request.goal.isEmpty {
            transcript.append(.userMessage(text: request.goal, timestamp: .now))
        }
        transcripts[session.id] = transcript
        startReplyTurn(session.id)
        return session.id
    }

    func handoff(_ sessionID: CompanionSession.ID, _ request: HandoffRequest) async throws {
        guard let session = session(sessionID) else { return }
        cancelTurn(sessionID)
        mutateTranscript(sessionID) {
            $0.append(.handoff(from: session.agent, to: request.agent, timestamp: .now))
        }
        mutateSession(sessionID) {
            $0.agent = request.agent
            $0.model = request.model
            $0.effort = request.effort
            $0.crashReason = nil
            $0.failure = nil
        }
        pending[sessionID] = []
        refreshAttention(sessionID)
        startReplyTurn(sessionID)
    }

    func restart(_ sessionID: CompanionSession.ID) async throws {
        mutateSession(sessionID) {
            $0.crashReason = nil
            $0.isProcessLive = true
        }
        mutateTranscript(sessionID) { $0.append(.systemNote(text: "Restarted", timestamp: .now)) }
        startReplyTurn(sessionID)
    }

    func delete(_ sessionID: CompanionSession.ID, removeWorktree: Bool) async throws {
        cancelTurn(sessionID)
        for macID in sessionsByMac.keys {
            sessionsByMac[macID]?.removeAll { $0.id == sessionID }
        }
        transcripts[sessionID] = nil
        pending[sessionID] = nil
        observationRevision &+= 1
    }

    func acknowledgeReview(_ sessionID: CompanionSession.ID) {
        mutateSession(sessionID) { $0.reviewAcknowledged = true }
    }

    // MARK: - Mutation helpers (also used by scenarios)

    func mutateSession(_ id: CompanionSession.ID, _ body: (inout CompanionSession) -> Void) {
        for macID in sessionsByMac.keys {
            if let index = sessionsByMac[macID]?.firstIndex(where: { $0.id == id }) {
                body(&sessionsByMac[macID]![index])
                sessionsByMac[macID]![index].updatedAt = .now
                observationRevision &+= 1
                return
            }
        }
    }

    func mutateTranscript(_ id: CompanionSession.ID, _ body: (inout SessionTranscript) -> Void) {
        body(&transcripts[id, default: SessionTranscript()])
    }

    func setReachable(_ reachable: Bool, macID: MacHost.ID) {
        guard let index = macs.firstIndex(where: { $0.id == macID }) else { return }
        if !reachable { macs[index].lastSeen = .now }
        macs[index].connection = reachable ? .connected(path: .lan, address: "192.168.1.20") : .unreachable
    }

    /// Raises a card and moves the session to waiting.
    func raise(_ interaction: PendingInteraction, in sessionID: CompanionSession.ID) {
        pending[sessionID, default: []].append(interaction)
        refreshAttention(sessionID)
    }

    /// The Mac answered first: the card shows the outcome, then retracts.
    func answerOnMac(_ interactionID: PendingInteraction.ID, in sessionID: CompanionSession.ID, outcome: String) async {
        guard let index = pending[sessionID]?.firstIndex(where: { $0.id == interactionID }) else { return }
        pending[sessionID]?[index].resolution = .answeredOnMac(outcome: outcome)
        try? await Task.sleep(for: .seconds(2))
        retract(interactionID, in: sessionID, outcome: outcome)
    }

    /// Removes a card the Mac resolved and lets the turn carry on.
    private func retract(_ interactionID: PendingInteraction.ID, in sessionID: CompanionSession.ID, outcome: String) {
        guard let current = pending[sessionID]?.firstIndex(where: { $0.id == interactionID }) else { return }
        let interaction = pending[sessionID]!.remove(at: current)
        answeredOnMacPendingRetraction.remove(interactionID)
        mutateTranscript(sessionID) {
            $0.append(.resolvedInteraction(text: "\(outcome) on Mac · \(Self.subject(of: interaction))", isPositive: outcome != "Denied"))
        }
        finishGatedCall(for: interactionID, in: sessionID, output: "Done", isError: false)
        refreshAttention(sessionID)
        continueIfUnblocked(sessionID, reply: "Picked that up from the Mac — carrying on.")
    }

    /// Runs `script` as the session's current turn, replacing any earlier one.
    func startTurn(_ sessionID: CompanionSession.ID, _ script: @escaping @MainActor (MockCompanionDataSource) async throws -> Void) {
        cancelTurn(sessionID)
        mutateSession(sessionID) { $0.status = .working; $0.isProcessLive = true }
        turnTasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            do {
                try await script(self)
            } catch {
                return
            }
        }
    }

    func cancelTurn(_ sessionID: CompanionSession.ID) {
        turnTasks[sessionID]?.cancel()
        turnTasks[sessionID] = nil
    }

    func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    // MARK: - Private

    private func refreshAttention(_ sessionID: CompanionSession.ID) {
        let open = pending[sessionID] ?? []
        mutateSession(sessionID) { session in
            if let first = open.first {
                session.status = .waitingForInput
                session.attentionSummary = first.attentionSummary
                session.waitingReason = switch first.kind {
                case .permission: .permission
                case .needsTerminal: nil
                case .question: .question
                case .plan: .planApproval
                }
            } else if session.status == .waitingForInput {
                session.status = .working
                session.waitingReason = nil
                session.attentionSummary = nil
            }
        }
    }

    private func finishGatedCall(for interactionID: PendingInteraction.ID, in sessionID: CompanionSession.ID, output: String, isError: Bool) {
        guard let gated = gatedToolCalls.removeValue(forKey: interactionID) else { return }
        mutateTranscript(sessionID) {
            $0.append(.toolResult(toolUseID: gated.useID, output: isError ? output : gated.output, isError: isError, timestamp: .now))
        }
    }

    private func continueIfUnblocked(_ sessionID: CompanionSession.ID, reply: String) {
        guard (pending[sessionID] ?? []).isEmpty else { return }
        startTurn(sessionID) { source in
            try await source.pause(0.8)
            try await source.streamReply(reply, in: sessionID)
            try await source.finishTurn(sessionID)
        }
    }

    private func startReplyTurn(_ sessionID: CompanionSession.ID) {
        startTurn(sessionID) { source in
            try await source.pause(0.6)
            try await source.runTool("Read", ["file_path": "FlotillaCompanion/App/CompanionStore.swift"], output: "212 lines", seconds: 0.8, in: sessionID)
            try await source.runTool("Bash", ["command": "swift build"], output: "Build complete!", seconds: 2.5, in: sessionID)
            try await source.streamReply(MockFixtures.sampleReply, in: sessionID)
            try await source.finishTurn(sessionID)
        }
    }

    /// Ends the turn, or picks up the next queued prompt.
    func finishTurn(_ sessionID: CompanionSession.ID) async throws {
        if let next = transcripts[sessionID]?.queuedPrompts.first {
            try await pause(0.8)
            mutateTranscript(sessionID) {
                $0.queuedPrompts.removeFirst()
                $0.append(.userMessage(text: next.text, timestamp: .now))
            }
            try await pause(0.6)
            try await streamReply("On it — folding that in now.", in: sessionID)
            try await finishTurn(sessionID)
            return
        }
        mutateSession(sessionID) {
            $0.status = .readyForReview
            $0.reviewAcknowledged = false
            $0.diffStat = diffs[sessionID]?.stat ?? $0.diffStat
        }
    }

    // MARK: - Naming

    static func title(from goal: String) -> String {
        let firstLine = goal.split(separator: "\n").first.map(String.init) ?? ""
        guard !firstLine.isEmpty else { return "New session" }
        return firstLine.count > 48 ? String(firstLine.prefix(47)) + "…" : firstLine
    }

    static func slug(from title: String) -> String {
        title.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, character in
                if character == "-", result.last == "-" { return }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .prefix(32)
            .description
    }

    private static func subject(of interaction: PendingInteraction) -> String {
        switch interaction.kind {
        case .permission(let request): "\(request.tool): \(request.summary)"
        case .question: "question"
        case .plan(let plan): plan.title
        case .needsTerminal(let title): title
        }
    }

    private static func resolutionText(for interaction: PendingInteraction, answer: InteractionAnswer) -> (String, Bool) {
        let subject = subject(of: interaction)
        return switch answer {
        case .allow, .allowWithNote: ("Allowed \(subject)", true)
        case .alwaysAllow: ("Always allowed \(subject)", true)
        case .deny, .denyWithNote: ("Denied \(subject)", false)
        case .denyAndStop: ("Denied and stopped · \(subject)", false)
        case .questionAnswers(let answers):
            ("Answered · " + answers.flatMap { $0.selected + ($0.other.map { [$0] } ?? []) }.joined(separator: ", "), true)
        case .approvePlan(let mode):
            switch mode {
            case .autoAccept: ("Approved plan · auto-accept edits", true)
            case .askForEdits: ("Approved plan · ask for edits", true)
            case nil: ("Approved plan", true)
            }
        case .revisePlan: ("Asked to revise the plan", false)
        }
    }
}
