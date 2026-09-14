import Foundation
import SessionKit
import CompanionKit

@MainActor
protocol CompanionSessionAdapter: AnyObject {
    /// Kept current by the registry: status and ids change after launch.
    var session: Session { get set }
    var pending: [PendingInteraction] { get }
    var transcript: SessionTranscript { get }
    func refresh() async throws
    func sendPrompt(_ text: String) async throws
    func stop() async throws
    func answer(_ id: UUID, with answer: InteractionAnswer) async throws -> AnswerOutcome
    func close()
}

/// An experimental-API peer of the app-server used by the Mac's Codex TUI.
@MainActor
final class CodexCompanionAdapter: CompanionSessionAdapter {
    private let rpc = ProviderRPC()
    private let endpoint: String
    var session: Session
    private var connected = false
    private var subscribedThreadID: String?
    private(set) var threadID: String?
    private var turnID: String?
    private var model: String
    private var requests: [UUID: Request] = [:]
    private var order: [UUID] = []
    private struct Request {
        var id: Any
        var method: String
        var thread: String
        var card: PendingInteraction
    }
    private(set) var transcript = SessionTranscript()
    var pending: [PendingInteraction] { order.compactMap { requests[$0]?.card } }

    init(session: Session, endpoint: String) {
        self.session = session
        self.endpoint = endpoint
        threadID = session.agentSessionID
        model = session.model ?? "gpt-5.6"
        rpc.onMessage = { [weak self] in self?.receive($0) }
        rpc.onDisconnect = { [weak self] in self?.connected = false; self?.subscribedThreadID = nil }
    }

    func refresh() async throws {
        if !connected { try await rpc.connect(socketPath: endpoint); connected = true }
        if threadID == nil { threadID = session.agentSessionID }
        if threadID == nil {
            let loaded = try await rpc.request("thread/loaded/list", params: [:])
            guard let ids = loaded["data"] as? [String] else { return }
            for id in ids {
                guard let result = try? await rpc.request("thread/read", params: ["threadId": id, "includeTurns": false]),
                      let thread = result["thread"] as? [String: Any],
                      let cwd = thread["cwd"] as? String,
                      URL(fileURLWithPath: cwd).resolvingSymlinksInPath() == session.workingDirectory.resolvingSymlinksInPath(),
                      !(thread["source"] is [String: Any]) else { continue }
                threadID = id; break
            }
        }
        if let threadID, subscribedThreadID != threadID {
            // Resume subscribes this peer. A fresh blank thread has no rollout
            // yet; retry on the next tick after its first user turn.
            if (try? await rpc.request("thread/resume", params: ["threadId": threadID, "excludeTurns": true])) != nil {
                subscribedThreadID = threadID
            }
        }
    }

    func sendPrompt(_ text: String) async throws {
        guard pending.isEmpty else { throw ProviderConnectionError.rejected("Answer the open dialog first.") }
        try await refresh()
        guard let threadID else { throw ProviderConnectionError.rejected("Codex is still starting.") }
        let input: [[String: Any]] = [["type": "text", "text": text, "text_elements": []]]
        if let turnID {
            _ = try await rpc.request("turn/steer", params: ["threadId": threadID, "expectedTurnId": turnID, "input": input])
        } else {
            let result = try await rpc.request("turn/start", params: ["threadId": threadID, "input": input])
            turnID = (result["turn"] as? [String: Any])?["id"] as? String
        }
    }

    func stop() async throws {
        guard let threadID, let turnID else { return }
        _ = try await rpc.request("turn/interrupt", params: ["threadId": threadID, "turnId": turnID])
    }

    func answer(_ id: UUID, with answer: InteractionAnswer) async throws -> AnswerOutcome {
        guard let request = requests[id] else { return .alreadyAnswered }
        var result: [String: Any]
        var note: String?
        switch request.card.kind {
        case .permission:
            let decision: String
            switch answer {
            case .allow: decision = "accept"
            case .alwaysAllow: decision = "acceptForSession"
            case .deny: decision = "decline"
            case .denyAndStop: decision = "cancel"
            case .allowWithNote(let text): decision = "accept"; note = text
            case .denyWithNote(let text): decision = "decline"; note = text
            default: throw ProviderConnectionError.rejected("That answer doesn't match this permission request.")
            }
            result = ["decision": decision]
        case .question(let steps):
            guard case .questionAnswers(let answers) = answer else { throw ProviderConnectionError.invalidResponse }
            var mapped: [String: Any] = [:]
            for step in steps {
                guard let value = answers.first(where: { $0.stepID == step.id }) else { throw ProviderConnectionError.rejected("Answer every question.") }
                let values = value.selected + (value.other.flatMap { $0.isEmpty ? nil : [$0] } ?? [])
                guard !values.isEmpty else { throw ProviderConnectionError.rejected("Answer every question.") }
                mapped[step.id] = ["answers": values]
            }
            result = ["answers": mapped]
        case .plan:
            guard let threadID else { throw ProviderConnectionError.disconnected }
            let text: String
            switch answer {
            case .approvePlan: text = "Implement the plan."
            case .revisePlan(let feedback): text = feedback
            default: throw ProviderConnectionError.invalidResponse
            }
            var params: [String: Any] = ["threadId": threadID, "input": [["type": "text", "text": text, "text_elements": []]]]
            if case .approvePlan = answer {
                params["collaborationMode"] = ["mode": "default", "settings": ["model": model, "reasoning_effort": session.effort?.rawValue ?? "medium", "developer_instructions": NSNull()]]
            }
            _ = try await rpc.request("turn/start", params: params)
            requests[id] = nil; order.removeAll { $0 == id }
            return .accepted
        case .needsTerminal: throw ProviderConnectionError.invalidResponse
        }
        try rpc.reply(id: request.id, result: result)
        requests[id] = nil; order.removeAll { $0 == id }
        if let note, !note.isEmpty {
            // The decision is already applied; a turn that ended meanwhile
            // takes the note as a new turn instead of failing the answer.
            let input: [[String: Any]] = [["type": "text", "text": note, "text_elements": []]]
            if let turnID, (try? await rpc.request("turn/steer", params: ["threadId": request.thread, "expectedTurnId": turnID, "input": input])) != nil {
                return .accepted
            }
            _ = try await rpc.request("turn/start", params: ["threadId": request.thread, "input": input])
        }
        return .accepted
    }

    func close() { rpc.close(); connected = false }

    func receive(_ message: [String: Any]) {
        guard let method = message["method"] as? String, let params = message["params"] as? [String: Any] else { return }
        let thread = params["threadId"] as? String ?? ""
        if let serverID = message["id"], method.hasSuffix("requestApproval") || method == "item/tool/requestUserInput" {
            // A server is dedicated to this Flotilla session, so child-thread
            // requests are attributable even before the first subscription.
            let card: PendingInteraction
            if method == "item/tool/requestUserInput" {
                let questions = (params["questions"] as? [[String: Any]] ?? []).map { value in
                    QuestionStep(id: value["id"] as? String ?? UUID().uuidString, header: value["header"] as? String ?? "Question", prompt: value["question"] as? String ?? "", options: (value["options"] as? [[String: Any]] ?? []).map { .init(label: $0["label"] as? String ?? "", description: $0["description"] as? String) }, allowsMultiple: value["isMultiple"] as? Bool ?? false, allowsFreeText: value["isOther"] as? Bool ?? false)
                }
                card = .init(kind: .question(questions), subagent: threadID != nil && thread != threadID ? "Codex subagent" : nil)
            } else {
                let summary = params["command"] as? String ?? params["reason"] as? String ?? "File changes"
                card = .init(kind: .permission(.init(tool: method.contains("commandExecution") ? "Command" : "Edit", summary: summary, detail: params["reason"] as? String)), subagent: threadID != nil && thread != threadID ? "Codex subagent" : nil)
            }
            requests[card.id] = .init(id: serverID, method: method, thread: thread, card: card)
            order.append(card.id)
            if threadID == nil { threadID = thread }
            if let turn = params["turnId"] as? String, thread == threadID { turnID = turn }
            return
        }
        if method == "serverRequest/resolved" {
            let resolved = String(describing: params["requestId"] ?? "")
            for id in order where requests[id].map({ String(describing: $0.id) == resolved }) == true { requests[id] = nil }
            order.removeAll { requests[$0] == nil }
            return
        }
        guard threadID == nil || thread.isEmpty || thread == threadID else { return }
        switch method {
        case "turn/started": turnID = (params["turn"] as? [String: Any])?["id"] as? String
        case "turn/completed":
            turnID = nil; transcript.streamingText = nil; transcript.isStopping = false; transcript.retryAttempt = nil
            if let turn = params["turn"] as? [String: Any], let error = turn["error"] as? [String: Any] { transcript.append(.turnFailed(message: error["message"] as? String ?? "Codex turn failed.")) }
        case "item/agentMessage/delta": transcript.streamingText = (transcript.streamingText ?? "") + (params["delta"] as? String ?? "")
        case "item/completed":
            guard let item = params["item"] as? [String: Any], let type = item["type"] as? String else { return }
            if type == "agentMessage" { transcript.append(.assistantMessage(text: item["text"] as? String ?? "", timestamp: .now)); transcript.streamingText = nil }
            if type == "plan" {
                let card = PendingInteraction(kind: .plan(.init(title: "Implement this plan?", markdown: item["text"] as? String ?? "")))
                requests[card.id] = .init(id: "plan", method: "plan", thread: thread, card: card); order.append(card.id)
            }
        // `error` notifications repeat as `turn/completed` with `status: failed`
        // unless Codex retries; only the retry count is new information.
        case "error": if params["willRetry"] as? Bool == true { transcript.retryAttempt = (transcript.retryAttempt ?? 0) + 1 }
        default: break
        }
    }
}
