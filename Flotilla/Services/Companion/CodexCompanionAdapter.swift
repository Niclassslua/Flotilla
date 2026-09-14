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
    private let rpc: any ProviderRPCServing
    private let endpoint: String
    private let screen: (() async -> String?)?
    private let send: ((Data) -> Void)?
    var session: Session
    private var connected = false
    private var refreshTask: Task<Void, Error>?
    private var subscribedThreadID: String?
    private(set) var threadID: String?
    private var turnID: String?
    private var model: String
    private var effort: String?
    private var requests: [UUID: Request] = [:]
    private var order: [UUID] = []
    private var answering: Set<UUID> = []
    private struct ItemKey: Hashable { var thread: String; var id: String }
    private var editPreviews: [ItemKey: PermissionRequest] = [:]
    private struct Request {
        var id: Any
        var method: String
        var thread: String
        var card: PendingInteraction
        var itemID: String? = nil
    }
    private(set) var transcript = SessionTranscript()
    var pending: [PendingInteraction] { order.compactMap { requests[$0]?.card } }
    private static let asyncQuestion = "asyncQuestion"

    init(session: Session, endpoint: String, rpc: any ProviderRPCServing = ProviderRPC(), screen: (() async -> String?)? = nil, send: ((Data) -> Void)? = nil) {
        self.session = session
        self.endpoint = endpoint
        self.rpc = rpc
        self.screen = screen
        self.send = send
        threadID = session.agentSessionID
        model = session.model ?? "gpt-5.6"
        effort = session.effort?.rawValue
        rpc.onMessage = { [weak self] in self?.receive($0) }
        rpc.onDisconnect = { [weak self] in self?.connected = false; self?.subscribedThreadID = nil }
    }

    func refresh() async throws {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await self.performRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    private func performRefresh() async throws {
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
            if let result = try? await rpc.request("thread/resume", params: ["threadId": threadID, "excludeTurns": true, "initialTurnsPage": ["limit": 1, "sortDirection": "desc", "itemsView": "full"]]) {
                subscribedThreadID = threadID
                model = result["model"] as? String ?? model
                effort = result["reasoningEffort"] as? String ?? effort
                let page = result["initialTurnsPage"] as? [String: Any]
                let thread = result["thread"] as? [String: Any]
                if let latest = (page?["data"] as? [[String: Any]])?.first ?? (thread?["turns"] as? [[String: Any]])?.last {
                    turnID = latest["status"] as? String == "inProgress" ? latest["id"] as? String : nil
                    // Only the latest turn can still ask for an answer. Older
                    // questions/plans have already been passed by a user turn.
                    let items = latest["items"] as? [[String: Any]] ?? []
                    let itemIDs = Set(items.compactMap { $0["id"] as? String })
                    for id in order where [Self.asyncQuestion, "plan"].contains(requests[id]?.method ?? "") {
                        if !itemIDs.contains(requests[id]?.id as? String ?? "") { requests[id] = nil }
                    }
                    order.removeAll { requests[$0] == nil }
                    for item in items {
                        rememberEdit(item, thread: threadID)
                        restoreInteraction(item, thread: threadID)
                    }
                }
            }
        }
    }

    func sendPrompt(_ text: String) async throws {
        guard pending.isEmpty else { throw ProviderConnectionError.rejected("Answer the open dialog first.") }
        try await refresh()
        guard pending.isEmpty else { throw ProviderConnectionError.rejected("Answer the open dialog first.") }
        guard let threadID else { throw ProviderConnectionError.rejected("Codex is still starting.") }
        try await submit(text, to: threadID)
    }

    func stop() async throws {
        try await refresh()
        guard let threadID, let turnID else { return }
        transcript.isStopping = true
        do { _ = try await rpc.request("turn/interrupt", params: ["threadId": threadID, "turnId": turnID]) }
        catch { transcript.isStopping = false; throw error }
    }

    func answer(_ id: UUID, with answer: InteractionAnswer) async throws -> AnswerOutcome {
        guard let request = requests[id] else { return .alreadyAnswered }
        guard answering.insert(id).inserted else { throw ProviderConnectionError.rejected("An answer is already being sent. Try again if it fails.") }
        defer { answering.remove(id) }
        var result: [String: Any]
        var note: String?
        switch request.card.kind {
        case .permission(let permission):
            let decision: String
            switch answer {
            case .allow: decision = "accept"
            case .alwaysAllow:
                guard permission.allowsAlwaysAllow != false else { throw ProviderConnectionError.invalidResponse }
                decision = "acceptForSession"
            case .deny: decision = "decline"
            case .denyAndStop:
                guard permission.allowsDenyAndStop != false else { throw ProviderConnectionError.invalidResponse }
                decision = "cancel"
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
                let other = value.other?.trimmingCharacters(in: .whitespacesAndNewlines)
                let values = value.selected + (other.flatMap { $0.isEmpty ? nil : [$0] } ?? [])
                guard !values.isEmpty else { throw ProviderConnectionError.rejected("Answer every question.") }
                guard value.selected.allSatisfy({ selection in step.options.contains { $0.label == selection } }),
                      step.allowsMultiple || values.count == 1,
                      other?.isEmpty != false || step.allowsFreeText != false else { throw ProviderConnectionError.invalidResponse }
                mapped[step.id] = ["answers": values]
            }
            if request.method == Self.asyncQuestion {
                // No reply channel: the answer is the user's next message.
                let text = steps.map { step in
                    let values = (mapped[step.id] as? [String: [String]])?["answers"] ?? []
                    return steps.count == 1 ? values.joined(separator: ", ") : "\(step.prompt) \(values.joined(separator: ", "))"
                }.joined(separator: "\n")
                try await submit(text, to: request.thread)
                requests[id] = nil; order.removeAll { $0 == id }
                return .accepted
            }
            result = ["answers": mapped]
        case .plan:
            let text: String
            switch answer {
            case .approvePlan: text = "Implement the plan."
            case .revisePlan(let feedback): text = feedback
            default: throw ProviderConnectionError.invalidResponse
            }
            guard turnID == nil else { throw ProviderConnectionError.rejected("Codex is still finishing the plan. Try again shortly.") }
            if let screen, let send, let text = await screen(),
               requests[id] != nil,
               text.contains("Implement this plan?"),
               text.contains("Yes, implement this plan"),
               text.contains("No, stay in Plan mode"),
               text.contains("esc to go back") {
                // This is a TUI-local selection view, not a server request.
                // Dismiss it while the turn is idle, before starting remote
                // work; Escape after turn/start could interrupt that work.
                send(Data([0x1B]))
            }
            guard requests[id] != nil else { return .alreadyAnswered }
            var params: [String: Any] = ["threadId": request.thread, "input": [["type": "text", "text": text, "text_elements": []]]]
            if case .approvePlan = answer {
                params["collaborationMode"] = ["mode": "default", "settings": ["model": model, "reasoning_effort": effort ?? "medium", "developer_instructions": NSNull()]]
            }
            let response = try await rpc.request("turn/start", params: params)
            turnID = (response["turn"] as? [String: Any])?["id"] as? String
            requests[id] = nil; order.removeAll { $0 == id }
            return .accepted
        case .needsTerminal: throw ProviderConnectionError.invalidResponse
        }
        try rpc.reply(id: request.id, result: result)
        requests[id] = nil; order.removeAll { $0 == id }
        if let note, !note.isEmpty {
            // The decision is already applied; a turn that ended meanwhile
            // takes the note as a new turn instead of failing the answer.
            try await submit(note, to: request.thread)
        }
        return .accepted
    }

    func close() { refreshTask?.cancel(); rpc.close(); connected = false; subscribedThreadID = nil }

    private func submit(_ text: String, to thread: String) async throws {
        let input: [[String: Any]] = [["type": "text", "text": text, "text_elements": []]]
        if let turnID, thread == threadID {
            do {
                _ = try await rpc.request("turn/steer", params: ["threadId": thread, "expectedTurnId": turnID, "input": input])
                return
            } catch ProviderConnectionError.requestFailed(let code, _) where code == -32600 {
                // The turn can finish between the notification and the send.
                // Only an explicit rejection permits retrying as a new turn;
                // a timeout/disconnect may already have delivered the input.
            }
        }
        let result = try await rpc.request("turn/start", params: ["threadId": thread, "input": input])
        if thread == threadID { turnID = (result["turn"] as? [String: Any])?["id"] as? String }
    }

    private func clearTurnInteractions() {
        for id in order where [Self.asyncQuestion, "plan"].contains(requests[id]?.method ?? "") { requests[id] = nil }
        order.removeAll { requests[$0] == nil }
    }

    func receive(_ message: [String: Any]) {
        guard let method = message["method"] as? String, let params = message["params"] as? [String: Any] else { return }
        let thread = params["threadId"] as? String ?? ""
        if method == "item/started", let item = params["item"] as? [String: Any], item["type"] as? String == "fileChange" {
            rememberEdit(item, thread: thread)
            return
        }
        if method == "item/completed", let item = params["item"] as? [String: Any], let id = item["id"] as? String {
            editPreviews[.init(thread: thread, id: id)] = nil
        }
        if let serverID = message["id"], method.hasSuffix("requestApproval") || method == "item/tool/requestUserInput" {
            // A server is dedicated to this Flotilla session, so child-thread
            // requests are attributable even before the first subscription.
            let card: PendingInteraction
            guard !requests.values.contains(where: { $0.method == method && String(describing: $0.id) == String(describing: serverID) }) else { return }
            if method == "item/tool/requestUserInput" {
                let questions = (params["questions"] as? [[String: Any]] ?? []).map { value in
                    QuestionStep(id: value["id"] as? String ?? UUID().uuidString, header: value["header"] as? String ?? "Question", prompt: value["question"] as? String ?? "", options: (value["options"] as? [[String: Any]] ?? []).map { .init(label: $0["label"] as? String ?? "", description: $0["description"] as? String) }, allowsMultiple: value["isMultiple"] as? Bool ?? false, allowsFreeText: value["isOther"] as? Bool == true || (value["options"] as? [[String: Any]] ?? []).isEmpty)
                }
                card = .init(kind: questions.isEmpty ? .needsTerminal(dialogTitle: "Question") : .question(questions), subagent: threadID != nil && thread != threadID ? "Codex subagent" : nil)
            } else if ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(method) {
                let edit = (params["itemId"] as? String).flatMap { editPreviews[.init(thread: thread, id: $0)] }
                let summary = params["command"] as? String ?? edit?.summary ?? params["reason"] as? String ?? "File changes"
                // Codex 0.154 accepts and caches acceptForSession even when
                // availableDecisions only advertises its TUI's policy choices.
                card = .init(kind: .permission(.init(tool: method.contains("commandExecution") ? "Command" : "Edit", summary: summary, detail: edit?.detail ?? params["reason"] as? String)), subagent: threadID != nil && thread != threadID ? "Codex subagent" : nil)
            } else {
                // Other approval methods use different reply schemas. Keep
                // their Mac dialog available instead of sending a wrong reply.
                card = .init(kind: .needsTerminal(dialogTitle: params["reason"] as? String ?? "Codex permission"))
            }
            requests[card.id] = .init(id: serverID, method: method, thread: thread, card: card, itemID: params["itemId"] as? String)
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
        if threadID == nil, !thread.isEmpty { threadID = thread }
        switch method {
        case "thread/settings/updated":
            if let settings = params["threadSettings"] as? [String: Any] {
                model = settings["model"] as? String ?? model
                effort = settings["effort"] as? String ?? effort
            }
        case "turn/started":
            turnID = (params["turn"] as? [String: Any])?["id"] as? String
            // Whoever starts the next turn — this peer or the TUI — has
            // answered or passed over an async question.
            clearTurnInteractions()
        case "turn/completed":
            if let completed = (params["turn"] as? [String: Any])?["id"] as? String,
               let turnID, completed != turnID { return }
            turnID = nil; transcript.streamingText = nil; transcript.isStopping = false; transcript.retryAttempt = nil
            if let turn = params["turn"] as? [String: Any], let error = turn["error"] as? [String: Any] { transcript.append(.turnFailed(message: error["message"] as? String ?? "Codex turn failed.")) }
        case "item/agentMessage/delta": transcript.streamingText = (transcript.streamingText ?? "") + (params["delta"] as? String ?? "")
        case "item/completed":
            guard let item = params["item"] as? [String: Any], let type = item["type"] as? String else { return }
            if type == "agentMessage" { transcript.append(.assistantMessage(text: item["text"] as? String ?? "", timestamp: .now)); transcript.streamingText = nil }
            restoreInteraction(item, thread: thread)
        // `error` notifications repeat as `turn/completed` with `status: failed`
        // unless Codex retries; only the retry count is new information.
        case "error": if params["willRetry"] as? Bool == true { transcript.retryAttempt = (transcript.retryAttempt ?? 0) + 1 }
        default: break
        }
    }

    private func restoreInteraction(_ item: [String: Any], thread: String) {
        let type = item["type"] as? String
        // Async questions return immediately. The model can keep working;
        // an answer is a steer until that turn ends, then a new user turn.
        if type == "agentMessage", item["delivery"] as? String == "async", let questions = item["questions"] as? [[String: Any]], !questions.isEmpty {
            guard !requests.values.contains(where: { $0.method == Self.asyncQuestion && $0.id as? String == item["id"] as? String }) else { return }
            let steps = questions.enumerated().map { index, question in
                QuestionStep(id: String(index), header: "Question", prompt: question["title"] as? String ?? "", options: (question["options"] as? [String] ?? []).map { .init(label: $0) }, allowsMultiple: false, allowsFreeText: true)
            }
            let card = PendingInteraction(kind: .question(steps), subagent: threadID != nil && thread != threadID ? "Codex subagent" : nil)
            requests[card.id] = .init(id: item["id"] as? String ?? Self.asyncQuestion, method: Self.asyncQuestion, thread: thread, card: card); order.append(card.id)
        }
        if type == "plan" {
            guard !(item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard !requests.values.contains(where: { $0.method == "plan" && $0.id as? String == item["id"] as? String }) else { return }
            for id in order where requests[id]?.method == "plan" { requests[id] = nil }
            order.removeAll { requests[$0] == nil }
            let card = PendingInteraction(kind: .plan(.init(title: "Implement this plan?", markdown: item["text"] as? String ?? "")))
            requests[card.id] = .init(id: item["id"] as? String ?? "plan", method: "plan", thread: thread, card: card); order.append(card.id)
        }
    }

    private func rememberEdit(_ item: [String: Any], thread: String) {
        guard item["type"] as? String == "fileChange", item["status"] as? String == "inProgress",
              let id = item["id"] as? String, let changes = item["changes"] as? [[String: Any]], !changes.isEmpty else { return }
        let paths = changes.compactMap { $0["path"] as? String }
        let detail = changes.map { "\($0["path"] as? String ?? "")\n\($0["diff"] as? String ?? "")" }.joined(separator: "\n\n")
        let preview = PermissionRequest(tool: "Edit", summary: paths.joined(separator: ", "), detail: detail)
        editPreviews[.init(thread: thread, id: id)] = preview
        // Resume can replay an open request before its item history arrives.
        for key in order where requests[key]?.method == "item/fileChange/requestApproval" && requests[key]?.thread == thread && requests[key]?.itemID == id {
            requests[key]?.card.kind = .permission(preview)
        }
    }
}
