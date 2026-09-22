import CompanionKit
import Foundation

/// Cursor Agent CLI hook payloads → phone cards, and answers → hook stdout.
///
/// Cursor expects `{"continue":true,"permission":"allow"|"deny",…}` — never
/// `ask` on `preToolUse` (silently treated as allow). Always-allow is a
/// Flotilla session memory; the CLI has no addRules field.
enum CursorPermissionPayload {
    struct Parsed {
        var toolName: String
        var toolInput: [String: Any]
        var toolUseID: String?
        var hookEventName: String?
        var command: String?
        var interaction: PendingInteraction
        /// Pattern used for session-scoped always-allow matching.
        var alwaysAllowPattern: String
    }

    static func parse(_ json: Data, id: UUID = UUID(), now: Date = .now) -> Parsed? {
        guard let envelope = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        guard envelope["flotilla_provider"] as? String == "cursor" else { return nil }

        let request = envelope["request"] as? [String: Any] ?? envelope
        let hookEvent = envelope["hook_event_name"] as? String
            ?? request["hook_event_name"] as? String
        let toolName = (request["tool_name"] as? String)
            ?? (request["toolName"] as? String)
            ?? (hookEvent == "beforeShellExecution" || hookEvent == "beforeMCPExecution" ? "Shell" : "Tool")
        let input = request["tool_input"] as? [String: Any]
            ?? request["toolInput"] as? [String: Any]
            ?? [:]
        let command = request["command"] as? String ?? input["command"] as? String
        let toolUseID = request["tool_use_id"] as? String ?? request["toolUseId"] as? String

        let kind: PendingInteraction.Kind
        switch toolName.lowercased() {
        case "askquestion", "ask_question", "request_user_input":
            if let steps = questionSteps(from: input), !steps.isEmpty {
                kind = .question(steps)
            } else {
                kind = .permission(PermissionRequest(
                    tool: toolName,
                    summary: summary(toolName: toolName, input: input, command: command),
                    detail: command ?? ClaudePermissionPayload.detail(toolName: toolName, input: input),
                    allowsAlwaysAllow: true,
                    allowsDenyAndStop: true
                ))
            }
        case "createplan", "exitplanmode", "create_plan":
            let plan = input["plan"] as? String
                ?? input["overview"] as? String
                ?? input["prompt"] as? String
                ?? ""
            kind = .plan(PlanProposal(title: ClaudePermissionPayload.planTitle(plan), markdown: plan))
        default:
            kind = .permission(PermissionRequest(
                tool: toolName,
                summary: summary(toolName: toolName, input: input, command: command),
                detail: command ?? ClaudePermissionPayload.detail(toolName: toolName, input: input),
                allowsAlwaysAllow: true,
                allowsDenyAndStop: true
            ))
        }

        let pattern = alwaysAllowPattern(toolName: toolName, command: command, input: input)
        return Parsed(
            toolName: toolName,
            toolInput: input,
            toolUseID: toolUseID,
            hookEventName: hookEvent,
            command: command,
            interaction: PendingInteraction(id: id, kind: kind, raisedAt: now),
            alwaysAllowPattern: pattern
        )
    }

    static func summary(toolName: String, input: [String: Any], command: String?) -> String {
        if let command, !command.isEmpty {
            return command.count > 160 ? String(command.prefix(157)) + "…" : command
        }
        return ClaudePermissionPayload.summary(toolName: toolName, input: input)
    }

    static func alwaysAllowPattern(toolName: String, command: String?, input: [String: Any]) -> String {
        if let command, !command.isEmpty {
            let first = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? command
            return "\(toolName):\(first)"
        }
        if let path = input["file_path"] as? String ?? input["path"] as? String {
            return "\(toolName):\(path)"
        }
        return toolName
    }

    private static func questionSteps(from input: [String: Any]) -> [QuestionStep]? {
        let questions = (input["questions"] as? [[String: Any]]) ?? []
        if !questions.isEmpty {
            return questions.enumerated().map { index, question in
                QuestionStep(
                    id: "q\(index)",
                    header: question["header"] as? String ?? "Question",
                    prompt: question["question"] as? String ?? question["prompt"] as? String ?? "",
                    options: ((question["options"] as? [[String: Any]]) ?? []).map {
                        QuestionStep.Option(
                            label: $0["label"] as? String ?? $0["id"] as? String ?? "",
                            description: $0["description"] as? String
                        )
                    },
                    allowsMultiple: question["multiSelect"] as? Bool ?? question["allowMultiple"] as? Bool ?? false
                )
            }
        }
        if let prompt = input["prompt"] as? String ?? input["question"] as? String {
            let options = ((input["options"] as? [[String: Any]]) ?? []).map {
                QuestionStep.Option(label: $0["label"] as? String ?? "", description: $0["description"] as? String)
            }
            return [QuestionStep(id: "q0", header: "Question", prompt: prompt, options: options, allowsMultiple: false)]
        }
        return nil
    }

    /// Hook stdout for Cursor. Questions and plan revise that need a follow-up
    /// prompt return deny + message (or allow) and leave prompting to the adapter.
    static func decision(for answer: InteractionAnswer, parsed: Parsed) -> Data? {
        var body: [String: Any] = ["continue": true]
        switch answer {
        case .allow, .allowWithNote, .alwaysAllow:
            body["permission"] = "allow"
        case .deny:
            body["permission"] = "deny"
            body["user_message"] = "Denied from Flotilla companion"
            body["agent_message"] = "The user denied this from their iPhone."
        case .denyWithNote(let note):
            body["permission"] = "deny"
            body["user_message"] = note
            body["agent_message"] = note
        case .denyAndStop:
            body["permission"] = "deny"
            body["user_message"] = "Denied and stopped from Flotilla companion"
            body["agent_message"] = "The user denied this and stopped the turn from their iPhone."
        case .questionAnswers(let answers):
            // Cursor has no updatedInput on hooks — allow and let the adapter
            // paste the chosen answers as a follow-up if needed.
            _ = answers
            body["permission"] = "allow"
        case .approvePlan:
            body["permission"] = "allow"
        case .revisePlan(let message):
            body["permission"] = "deny"
            body["user_message"] = message
            body["agent_message"] = message
        }
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}
