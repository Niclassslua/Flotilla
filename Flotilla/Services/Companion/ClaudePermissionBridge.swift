import Foundation
import Network
import CompanionKit

/// Claude Code's `PermissionRequest` payloads, turned into phone cards, and the
/// phone's answers, turned back into hook decisions.
///
/// Pure value code, kept apart from the socket so the mapping is unit-tested.
enum ClaudePermissionPayload {
    struct Parsed {
        var toolName: String
        var toolInput: [String: Any]
        var suggestions: [Any]?
        var interaction: PendingInteraction
    }

    static func parse(_ json: Data, id: UUID = UUID(), now: Date = .now) -> Parsed? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let toolName = object["tool_name"] as? String else { return nil }
        let input = object["tool_input"] as? [String: Any] ?? [:]
        let subagent = object["agent_type"] as? String

        let kind: PendingInteraction.Kind
        switch toolName {
        case "AskUserQuestion":
            let questions = (input["questions"] as? [[String: Any]]) ?? []
            let steps = questions.enumerated().map { index, question in
                QuestionStep(
                    id: "q\(index)",
                    header: question["header"] as? String ?? "Question",
                    prompt: question["question"] as? String ?? "",
                    options: ((question["options"] as? [[String: Any]]) ?? []).map {
                        QuestionStep.Option(label: $0["label"] as? String ?? "", description: $0["description"] as? String)
                    },
                    allowsMultiple: question["multiSelect"] as? Bool ?? false
                )
            }
            guard !steps.isEmpty else { return nil }
            kind = .question(steps)
        case "ExitPlanMode":
            let plan = input["plan"] as? String ?? ""
            kind = .plan(PlanProposal(title: planTitle(plan), markdown: plan))
        default:
            kind = .permission(PermissionRequest(
                tool: toolName,
                summary: summary(toolName: toolName, input: input),
                detail: detail(toolName: toolName, input: input)
            ))
        }
        return Parsed(
            toolName: toolName,
            toolInput: input,
            suggestions: object["permission_suggestions"] as? [Any],
            interaction: PendingInteraction(id: id, kind: kind, subagent: subagent, raisedAt: now)
        )
    }

    static func summary(toolName: String, input: [String: Any]) -> String {
        for key in ["command", "file_path", "path", "url", "pattern", "query", "description", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty {
                return value.count > 160 ? String(value.prefix(157)) + "…" : value
            }
        }
        return toolName
    }

    static func detail(toolName: String, input: [String: Any]) -> String? {
        if let command = input["command"] as? String { return command }
        if let content = input["new_string"] as? String {
            let old = input["old_string"] as? String ?? ""
            let removed = old.split(separator: "\n", omittingEmptySubsequences: false).map { "- \($0)" }
            let added = content.split(separator: "\n", omittingEmptySubsequences: false).map { "+ \($0)" }
            return (removed + added).prefix(12).joined(separator: "\n")
        }
        if let content = input["content"] as? String {
            return content.split(separator: "\n", omittingEmptySubsequences: false).prefix(12).joined(separator: "\n")
        }
        return nil
    }

    static func planTitle(_ markdown: String) -> String {
        let heading = markdown.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("#") }?
            .drop { $0 == "#" }
            .trimmingCharacters(in: .whitespaces)
        return heading.flatMap { $0.isEmpty ? nil : $0 } ?? "Plan"
    }

    /// The hook's stdout for an answer. `nil` for answers that have no
    /// decision form — the caller must not answer those through the hook.
    static func decision(for answer: InteractionAnswer, parsed: Parsed) -> Data? {
        var decision: [String: Any]
        switch answer {
        case .allow, .allowWithNote:
            decision = ["behavior": "allow"]
        case .alwaysAllow:
            decision = [
                "behavior": "allow",
                "updatedPermissions": parsed.suggestions ?? [[
                    "type": "addRules",
                    "rules": [["toolName": parsed.toolName]],
                    "behavior": "allow",
                    "destination": "session",
                ]],
            ]
        case .deny:
            decision = ["behavior": "deny", "message": "The user denied this from their iPhone."]
        case .denyWithNote(let note):
            decision = ["behavior": "deny", "message": note]
        case .denyAndStop:
            decision = ["behavior": "deny", "message": "The user denied this and stopped the turn from their iPhone.", "interrupt": true]
        case .questionAnswers(let answers):
            guard case .question(let steps) = parsed.interaction.kind else { return nil }
            var byQuestion: [String: String] = [:]
            for step in steps {
                guard let answer = answers.first(where: { $0.stepID == step.id }) else { continue }
                let values = answer.selected + (answer.other.map { [$0] } ?? [])
                byQuestion[step.prompt] = values.joined(separator: ", ")
            }
            var updated = parsed.toolInput
            updated["answers"] = byQuestion
            decision = ["behavior": "allow", "updatedInput": updated]
        case .approvePlan(let mode):
            decision = ["behavior": "allow", "updatedInput": parsed.toolInput]
            if let mode {
                decision["updatedPermissions"] = [[
                    "type": "setMode",
                    "mode": mode == .autoAccept ? "acceptEdits" : "default",
                    "destination": "session",
                ]]
            }
        case .revisePlan(let message):
            decision = ["behavior": "deny", "message": message]
        }
        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ]
        ]
        return try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    }
}

/// Holds Claude Code permission requests for the phone.
///
/// Each request arrives on the companion socket as two lines — the session's
/// hook event-file path (which names the Flotilla session) and the hook JSON —
/// and the connection stays open until someone answers. Answering writes the
/// decision and closes; retracting closes without writing, which the hook
/// shim turns into "no decision", leaving the terminal dialog in charge.
@MainActor
final class ClaudePermissionBridge {
    private final class Held {
        let parsed: ClaudePermissionPayload.Parsed
        let connection: NWConnection

        init(parsed: ClaudePermissionPayload.Parsed, connection: NWConnection) {
            self.parsed = parsed
            self.connection = connection
        }
    }

    private var listener: NWListener?
    private var held: [UUID: [Held]] = [:]
    /// When a session was first observed not-waiting, per session — reset the
    /// moment it reads as waiting again. `retractResolved` only acts once this
    /// has held continuously past the grace window, so one misread from the
    /// status heuristic can't drop a request a human is still reading.
    private var notWaitingSince: [UUID: Date] = [:]
    private let queue = DispatchQueue(label: "companion.claude-bridge")

    /// Called whenever the set of held requests changes.
    var onChange: () -> Void = {}
    /// Called with a note the user attached to an Allow, to send as a prompt.
    var onAllowNote: (UUID, String) -> Void = { _, _ in }

    private(set) var socketURL: URL?

    func start(socketURL: URL) {
        stop()
        try? FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(socketURL.path)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socketURL.path)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.start(queue: queue)
        self.listener = listener
        self.socketURL = socketURL
    }

    func stop() {
        listener?.cancel()
        listener = nil
        if let socketURL { unlink(socketURL.path) }
        socketURL = nil
        for requests in held.values { requests.forEach { $0.connection.cancel() } }
        held = [:]
        notWaitingSince = [:]
        onChange()
    }

    func pending(for sessionID: UUID) -> [PendingInteraction] {
        held[sessionID]?.map(\.parsed.interaction) ?? []
    }

    var sessionsWithPending: Set<UUID> { Set(held.filter { !$0.value.isEmpty }.keys) }

    func hasPending(_ sessionID: UUID) -> Bool {
        !(held[sessionID] ?? []).isEmpty
    }

    func answer(sessionID: UUID, interactionID: UUID, with answer: InteractionAnswer) -> AnswerOutcome {
        guard let index = held[sessionID]?.firstIndex(where: { $0.parsed.interaction.id == interactionID }),
              let request = held[sessionID]?[index],
              let decision = ClaudePermissionPayload.decision(for: answer, parsed: request.parsed) else {
            return .alreadyAnswered
        }
        held[sessionID]?.remove(at: index)
        request.connection.send(content: decision + Data("\n".utf8), isComplete: true, completion: .contentProcessed { _ in
            request.connection.cancel()
        })
        if case .allowWithNote(let note) = answer, !note.isEmpty {
            onAllowNote(sessionID, note)
        }
        onChange()
        return .accepted
    }

    /// Denies the oldest held request with an interrupt — the stop path while a
    /// dialog is open, since Escape would also answer it.
    func denyAndStop(sessionID: UUID) -> Bool {
        guard let first = held[sessionID]?.first else { return false }
        return answer(sessionID: sessionID, interactionID: first.parsed.interaction.id, with: .denyAndStop) == .accepted
    }

    /// Drops requests the terminal has already dealt with: the session left
    /// waiting (answered at the Mac, Esc, turn end). A short grace covers the
    /// moment before the hook's own status update lands — measured from when
    /// the session *became* not-waiting, not from how old the request is, so
    /// a request that's simply taking a human a while to answer on the phone
    /// isn't mistaken for one the terminal already resolved.
    func retractResolved(isWaiting: (UUID) -> Bool, now: Date = .now) {
        var changed = false
        for sessionID in held.keys {
            guard !isWaiting(sessionID) else {
                notWaitingSince[sessionID] = nil
                continue
            }
            let since = notWaitingSince[sessionID] ?? now
            notWaitingSince[sessionID] = since
            guard now.timeIntervalSince(since) > 3,
                  let requests = held[sessionID], !requests.isEmpty else { continue }
            requests.forEach { $0.connection.cancel() }
            held[sessionID] = []
            notWaitingSince[sessionID] = nil
            changed = true
        }
        if changed { onChange() }
    }

    func retractAll(sessionID: UUID) {
        guard let requests = held.removeValue(forKey: sessionID) else { return }
        requests.forEach { $0.connection.cancel() }
        notWaitingSince[sessionID] = nil
        onChange()
    }

    // MARK: - Socket

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        Self.readTwoLines(connection) { [weak self] lines in
            Task { @MainActor in
                guard let self, let lines,
                      let sessionID = UUID(uuidString: URL(fileURLWithPath: lines.0).deletingPathExtension().lastPathComponent),
                      let parsed = ClaudePermissionPayload.parse(Data(lines.1.utf8)) else {
                    connection.cancel()
                    return
                }
                connection.stateUpdateHandler = { [weak self] state in
                    // The hook process went away (Claude answered locally and
                    // killed it, or the session ended): forget the request.
                    if case .cancelled = state { return }
                    if case .failed = state {
                        Task { @MainActor in self?.drop(connection, sessionID: sessionID) }
                    }
                }
                self.held[sessionID, default: []].append(Held(parsed: parsed, connection: connection))
                self.onChange()
            }
        }
    }

    private func drop(_ connection: NWConnection, sessionID: UUID) {
        guard let requests = held[sessionID], requests.contains(where: { $0.connection === connection }) else { return }
        held[sessionID] = requests.filter { $0.connection !== connection }
        onChange()
    }

    private nonisolated static func readTwoLines(_ connection: NWConnection, buffer: Data = Data(), completion: @escaping @Sendable ((String, String)?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            let text = String(decoding: buffer, as: UTF8.self)
            let lines = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
            if lines.count >= 3 {
                completion((String(lines[0]), String(lines[1])))
            } else if error != nil || isComplete || buffer.count > 4 * 1024 * 1024 {
                completion(nil)
            } else {
                readTwoLines(connection, buffer: buffer, completion: completion)
            }
        }
    }
}
