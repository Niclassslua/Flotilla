import Foundation
import SessionKit
import CompanionKit

@MainActor
final class OpenCodeCompanionAdapter: CompanionSessionAdapter {
    private let endpoint: URL
    private let password: String
    var session: Session
    private let createdAt: Date
    private var nativeID: String?
    private var requests: [UUID: Request] = [:]
    private var order: [UUID] = []
    private var eventTask: Task<Void, Never>?
    private let client = URLSession(configuration: .ephemeral)
    private struct Request { var nativeID: String; var question: Bool; var card: PendingInteraction }
    private(set) var transcript = SessionTranscript()
    var pending: [PendingInteraction] { order.compactMap { requests[$0]?.card } }

    init(session: Session, descriptor: CompanionRuntimeDescriptor) {
        self.session = session
        endpoint = URL(string: descriptor.endpoint)!
        password = descriptor.password ?? ""
        createdAt = descriptor.createdAt
        nativeID = session.agentSessionID
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Any {
        var request = authorized(path)
        request.httpMethod = method
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await client.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw ProviderConnectionError.rejected("OpenCode rejected the request.") }
        if data.isEmpty { return NSNull() }
        return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    private func authorized(_ path: String) -> URLRequest {
        var request = URLRequest(url: endpoint.appendingPathComponent(path), timeoutInterval: 10)
        request.setValue("Basic " + Data("opencode:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue(session.workingDirectory.path, forHTTPHeaderField: "x-opencode-directory")
        return request
    }

    func refresh() async throws {
        if eventTask == nil { startEvents() }
        let sessions = try await request("GET", "session") as? [[String: Any]] ?? []
        if nativeID == nil {
            nativeID = sessions.filter { $0["parentID"] == nil && ($0["directory"] as? String) == session.workingDirectory.path && (($0["time"] as? [String: Any])?["created"] as? Double ?? 0) >= createdAt.timeIntervalSince1970 * 1000 - 2000 }.sorted { (($0["time"] as? [String: Any])?["created"] as? Double ?? 0) > (($1["time"] as? [String: Any])?["created"] as? Double ?? 0) }.first?["id"] as? String
            if nativeID == nil, Date().timeIntervalSince(createdAt) > 3 {
                let created = try await request("POST", "session", body: ["title": session.title]) as? [String: Any]
                nativeID = created?["id"] as? String
                if let nativeID { _ = try await request("POST", "tui/select-session", body: ["sessionID": nativeID]) }
            }
        }
        guard let nativeID else { return }
        var related: Set<String> = [nativeID]
        for _ in sessions {
            for value in sessions {
                if let parent = value["parentID"] as? String, related.contains(parent), let id = value["id"] as? String { related.insert(id) }
            }
        }
        let permissions = try await request("GET", "permission") as? [[String: Any]] ?? []
        let questions = try await request("GET", "question") as? [[String: Any]] ?? []
        reconcile(permissions: permissions.filter { related.contains($0["sessionID"] as? String ?? "") }, questions: questions.filter { related.contains($0["sessionID"] as? String ?? "") })
        let rows = try await request("GET", "session/\(nativeID)/message") as? [[String: Any]] ?? []
        var events: [TranscriptEvent] = []
        for row in rows {
            guard let info = row["info"] as? [String: Any], let id = info["id"] as? String else { continue }
            let timestamp = Date(timeIntervalSince1970: ((info["time"] as? [String: Any])?["created"] as? Double ?? 0) / 1000)
            for part in row["parts"] as? [[String: Any]] ?? [] {
                let partID = part["id"] as? String ?? id
                if part["type"] as? String == "text", let text = part["text"] as? String {
                    let content: TranscriptEvent.Content = info["role"] as? String == "user" ? .userMessage(text: text, timestamp: timestamp) : .assistantMessage(text: text, timestamp: timestamp)
                    events.append(.init(id: partID, content: content))
                }
                if part["type"] as? String == "tool", let state = part["state"] as? [String: Any] {
                    let input = (state["input"] as? [String: Any] ?? [:]).mapValues { String(describing: $0) }
                    events.append(.init(id: partID, content: .toolUse(id: partID, tool: part["tool"] as? String ?? "Tool", input: input, timestamp: timestamp)))
                    if let output = state["output"] as? String { events.append(.init(id: partID + ":result", content: .toolResult(toolUseID: partID, output: output, isError: false, timestamp: timestamp))) }
                    // A rejected or failed call has no output, only its error.
                    else if let error = state["error"] as? String { events.append(.init(id: partID + ":result", content: .toolResult(toolUseID: partID, output: error, isError: true, timestamp: timestamp))) }
                }
            }
            if let error = info["error"] as? [String: Any] { events.append(.init(id: id + ":error", content: .turnFailed(message: (error["data"] as? [String: Any])?["message"] as? String ?? "OpenCode turn failed."))) }
        }
        transcript.events = events
    }

    func reconcile(permissions: [[String: Any]], questions: [[String: Any]]) {
        var active = Set<String>()
        for value in permissions + questions {
            guard let native = value["id"] as? String else { continue }
            active.insert(native)
            guard !requests.values.contains(where: { $0.nativeID == native }) else { continue }
            let isQuestion = value["questions"] != nil
            let kind: PendingInteraction.Kind
            if isQuestion {
                let steps = (value["questions"] as? [[String: Any]] ?? []).enumerated().map { index, question in
                    QuestionStep(id: String(index), header: question["header"] as? String ?? "Question", prompt: question["question"] as? String ?? "", options: (question["options"] as? [[String: Any]] ?? []).map { .init(label: $0["label"] as? String ?? "", description: $0["description"] as? String) }, allowsMultiple: question["multiple"] as? Bool ?? false)
                }
                kind = .question(steps)
            } else {
                let patterns = value["patterns"] as? [String] ?? []
                kind = .permission(.init(tool: value["permission"] as? String ?? "Tool", summary: patterns.joined(separator: ", "), detail: (value["metadata"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) }, pattern: (value["always"] as? [String] ?? patterns).joined(separator: ", ")))
            }
            let card = PendingInteraction(kind: kind, subagent: value["sessionID"] as? String != nativeID ? "OpenCode subagent" : nil)
            requests[card.id] = .init(nativeID: native, question: isQuestion, card: card); order.append(card.id)
        }
        requests = requests.filter { active.contains($0.value.nativeID) }
        order.removeAll { requests[$0] == nil }
    }

    func sendPrompt(_ text: String) async throws {
        guard pending.isEmpty else { throw ProviderConnectionError.rejected("Answer the open dialog first.") }
        try await prompt(text)
    }

    private func prompt(_ text: String, agent: String? = nil) async throws {
        try await refresh()
        guard let nativeID else { throw ProviderConnectionError.rejected("OpenCode is still starting.") }
        var body: [String: Any] = ["parts": [["type": "text", "text": text]]]
        if let agent { body["agent"] = agent }
        if let model = session.model, let slash = model.firstIndex(of: "/") { body["model"] = ["providerID": String(model[..<slash]), "modelID": String(model[model.index(after: slash)...])] }
        _ = try await request("POST", "session/\(nativeID)/prompt_async", body: body)
    }

    func stop() async throws {
        guard let nativeID else { return }
        _ = try await request("POST", "session/\(nativeID)/abort")
    }

    func answer(_ id: UUID, with answer: InteractionAnswer) async throws -> AnswerOutcome {
        // Reconciliation is mandatory before replying: SSE can arrive late.
        try await refresh()
        guard let pending = requests[id] else { return .alreadyAnswered }
        if pending.question {
            guard case .question(let steps) = pending.card.kind, case .questionAnswers(let answers) = answer else { throw ProviderConnectionError.invalidResponse }
            let values = try steps.map { step -> [String] in
                guard let value = answers.first(where: { $0.stepID == step.id }) else { throw ProviderConnectionError.invalidResponse }
                return value.selected + (value.other.flatMap { $0.isEmpty ? nil : [$0] } ?? [])
            }
            _ = try await request("POST", "question/\(pending.nativeID)/reply", body: ["answers": values])
        } else {
            var body: [String: Any]
            switch answer {
            case .allow: body = ["reply": "once"]
            case .alwaysAllow: body = ["reply": "always"]
            case .deny: body = ["reply": "reject"]
            case .denyAndStop: body = ["reply": "reject"]
            case .denyWithNote(let text): body = ["reply": "reject", "message": text]
            case .allowWithNote(let text): body = ["reply": "once", "message": text]
            default: throw ProviderConnectionError.invalidResponse
            }
            _ = try await request("POST", "permission/\(pending.nativeID)/reply", body: body)
            if case .denyAndStop = answer { try await stop() }
        }
        requests[id] = nil; order.removeAll { $0 == id }
        return .accepted
    }

    private func startEvents() {
        eventTask = Task { [weak self] in
            guard let self else { return }
            defer { self.eventTask = nil }
            do {
                var request = self.authorized("event"); request.timeoutInterval = 3600
                let (bytes, response) = try await self.client.bytes(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                for try await line in bytes.lines {
                    guard !Task.isCancelled else { return }
                    if line.hasPrefix("data: "), let event = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any] { self.receive(event) }
                }
            } catch { }
        }
    }

    func receive(_ event: [String: Any]) {
        guard let type = event["type"] as? String, let properties = event["properties"] as? [String: Any], properties["sessionID"] as? String == nativeID else { return }
        if type == "message.part.delta", properties["field"] as? String == "text" { transcript.streamingText = (transcript.streamingText ?? "") + (properties["delta"] as? String ?? "") }
        if type == "session.idle" { transcript.streamingText = nil; transcript.isStopping = false }
        if type == "session.error" { transcript.append(.turnFailed(message: ((properties["error"] as? [String: Any])?["data"] as? [String: Any])?["message"] as? String ?? "OpenCode turn failed.")) }
        if type == "session.status", let status = properties["status"] as? [String: Any] { transcript.retryAttempt = status["attempt"] as? Int }
    }

    func close() { eventTask?.cancel(); eventTask = nil; client.invalidateAndCancel() }
}
