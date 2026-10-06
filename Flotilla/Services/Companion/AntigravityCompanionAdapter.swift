import Foundation
import SessionKit
import CompanionKit
import HooksKit

/// Antigravity has no peer API for a live TUI. The log is authoritative for
/// request lifetime; the screen supplies the current keys and option labels.
@MainActor
final class AntigravityCompanionAdapter: CompanionSessionAdapter {
    var session: Session
    private let logURL: URL
    private let eventsURL: URL
    private let screen: (UUID) async -> String?
    private let send: (Data) -> Void
    private var requests: [UUID: Request] = [:]
    private var order: [UUID] = []
    private var reportedStops: Set<String> = []
    private struct Request {
        var conversation: String
        var step: Int
        var card: PendingInteraction
        var tool: String
    }
    private(set) var transcript = SessionTranscript()
    var pending: [PendingInteraction] { order.compactMap { requests[$0]?.card } }

    init(session: Session, descriptor: CompanionRuntimeDescriptor, support: URL, screen: @escaping (UUID) async -> String?, send: @escaping (Data) -> Void) {
        self.session = session
        logURL = URL(fileURLWithPath: descriptor.endpoint)
        eventsURL = HookConfigurationWriter.eventFilePath(for: session.id, supportDirectory: support)
        self.screen = screen
        self.send = send
    }

    private func log() -> String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }

    private func readRecentEvents(maxBytes: Int = 64 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: eventsURL) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size <= UInt64(maxBytes) {
            try? handle.seek(toOffset: 0)
            let data = (try? handle.readToEnd()) ?? Data()
            return String(data: data, encoding: .utf8) ?? ""
        }
        let offset = size - UInt64(maxBytes)
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return "" }
        if let firstNewline = text.firstIndex(of: "\n") {
            return String(text[text.index(after: firstNewline)...])
        }
        return text
    }

    nonisolated static func isOpen(step: Int, conversation: String, tool: String, log: String) -> Bool {
        guard log.contains("Surfacing") else { return false }
        return isOpen(step: step, conversation: conversation, tool: tool, lines: log.components(separatedBy: "\n"))
    }

    nonisolated static func isOpen(step: Int, conversation: String, tool: String, lines: [String]) -> Bool {
        let opened = lines.lastIndex { $0.contains("Surfacing") && $0.contains("step \(step)") && ($0.contains("tool confirmation") || $0.contains("ask_question")) }
        guard let opened else { return false }
        return !lines.dropFirst(opened + 1).contains {
            ($0.contains("stepIdx=\(step),") && $0.contains("convID=\(conversation)")) ||
            ($0.contains("AskQuestion response") && $0.contains("step \(step) ")) ||
            $0.contains("Interrupt cleared pending tool confirmation")
        }
    }

    func refresh() async throws {
        let log = log()
        let hasSurfacing = log.contains("Surfacing")
        let logLines = hasSurfacing ? log.components(separatedBy: "\n") : []

        requests = requests.filter { entry in
            if case .plan = entry.value.card.kind { return true }
            guard hasSurfacing else { return false }
            return Self.isOpen(step: entry.value.step, conversation: entry.value.conversation, tool: entry.value.tool, lines: logLines)
        }
        order.removeAll { requests[$0] == nil }

        let events = readRecentEvents()
        for line in events.split(separator: "\n") {
            if line.contains(#""event":"Stop""#) {
                noteFailedTurn(line)
                continue
            }
            // Fast reject lines that cannot contain an interactive prompt or plan
            guard line.contains("PreToolUse") || (line.contains("PostToolUse") && line.contains("write_to_file")) else { continue }
            if !hasSurfacing && line.contains("PreToolUse") { continue }

            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = event["payload"] as? [String: Any],
                  let step = payload["stepIdx"] as? Int,
                  let conversation = payload["conversationId"] as? String,
                  let toolCall = payload["toolCall"] as? [String: Any],
                  let tool = toolCall["name"] as? String,
                  let args = toolCall["args"] as? [String: Any],
                  !requests.values.contains(where: { $0.step == step && $0.conversation == conversation }) else { continue }
            let kind: PendingInteraction.Kind
            if event["event"] as? String == "PostToolUse", tool == "write_to_file", (args["ArtifactMetadata"] as? [String: Any])?["RequestFeedback"] as? Bool == true {
                kind = .plan(.init(title: args["TargetFile"] as? String ?? "Review the plan", markdown: args["CodeContent"] as? String ?? ""))
            } else {
                guard event["event"] as? String == "PreToolUse", Self.isOpen(step: step, conversation: conversation, tool: tool, lines: logLines) else { continue }
                if tool == "ask_question" {
                    let questions = args["questions"] as? [[String: Any]] ?? [args]
                    kind = .question(questions.enumerated().map { index, question in
                        let options = (question["options"] as? [Any] ?? []).map { option -> QuestionStep.Option in
                            if let option = option as? String { return .init(label: option) }
                            let value = option as? [String: Any] ?? [:]
                            return .init(label: value["label"] as? String ?? value["text"] as? String ?? "", description: value["description"] as? String)
                        }
                        return .init(id: String(index), header: question["header"] as? String ?? "Question", prompt: question["question"] as? String ?? question["prompt"] as? String ?? "Question", options: options, allowsMultiple: question["is_multi_select"] as? Bool ?? question["multiple"] as? Bool ?? question["multiSelect"] as? Bool ?? false)
                    })
                } else {
                    kind = .permission(.init(tool: tool, summary: args["CommandLine"] as? String ?? args["TargetFile"] as? String ?? tool, detail: args["CodeContent"] as? String))
                }
            }
            let card = PendingInteraction(kind: kind, subagent: session.agentSessionID != nil && conversation != session.agentSessionID ? "Antigravity subagent" : nil)
            requests[card.id] = .init(conversation: conversation, step: step, card: card, tool: tool); order.append(card.id)
        }
        // A resolved grant can surface and disappear within the same tick.
        // Recheck after a short settling period before showing native cards.
        if !requests.isEmpty {
            try await Task.sleep(for: .milliseconds(300))
            let current = self.log()
            let currentHasSurfacing = current.contains("Surfacing")
            let currentLines = currentHasSurfacing ? current.components(separatedBy: "\n") : []
            requests = requests.filter {
                if case .plan = $0.value.card.kind { return true }
                guard currentHasSurfacing else { return false }
                return Self.isOpen(step: $0.value.step, conversation: $0.value.conversation, tool: $0.value.tool, lines: currentLines)
            }
            order.removeAll { requests[$0] == nil }
        }
        if log.localizedCaseInsensitiveContains("retry") {
            let retryLines = logLines.isEmpty ? log.components(separatedBy: "\n") : logLines
            if let retry = retryLines.last(where: { $0.localizedCaseInsensitiveContains("retry") }) {
                transcript.retryAttempt = retry.split(whereSeparator: { !$0.isNumber }).last.flatMap { Int($0) }
            }
        }
    }

    /// A `Stop` that carries an `error` (or ended on a step limit) becomes a
    /// failed-turn note, once: the event tail is re-read on every refresh.
    private func noteFailedTurn(_ line: Substring) {
        guard !reportedStops.contains(String(line)),
              let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let payload = event["payload"] as? [String: Any],
              let message = Self.failureMessage(payload) else { return }
        reportedStops.insert(String(line))
        transcript.append(.turnFailed(message: message))
    }

    /// `Stop.error` is the failure; a `terminationReason` naming a step limit
    /// ends the turn without one. `NO_TOOL_CALL` is the ordinary end.
    nonisolated static func failureMessage(_ payload: [String: Any]) -> String? {
        let error = (payload["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let reason = (payload["terminationReason"] as? String) ?? ""
        if let error { return "Antigravity stopped: \(error)" }
        if reason.localizedCaseInsensitiveContains("max_steps") {
            return "Antigravity stopped: it reached its step limit."
        }
        return nil
    }

    /// Parse displayed option numbers; command and file confirmations have
    /// different layouts, and provider updates may reorder their choices.
    /// Only the last numbered block counts: earlier dialogs can linger in
    /// the scrollback above the open one.
    nonisolated static func options(in screen: String) -> [(key: String, label: String, isHighlighted: Bool)] {
        let regex = try! NSRegularExpression(pattern: #"^\s*([›❯>])?\s*([1-9])(?:[.)]|\s+\[[ x]\])\s+(.+)$"#)
        var block: [(key: String, label: String, isHighlighted: Bool)] = []
        for line in screen.components(separatedBy: "\n") {
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let key = Range(match.range(at: 2), in: line),
                  let label = Range(match.range(at: 3), in: line) else { continue }
            if line[key] == "1" { block = [] }
            block.append((String(line[key]), String(line[label]).trimmingCharacters(in: .whitespaces), match.range(at: 1).location != NSNotFound))
        }
        return block
    }

    func answer(_ id: UUID, with answer: InteractionAnswer) async throws -> AnswerOutcome {
        guard let request = requests[id] else { return .alreadyAnswered }
        if case .plan(let plan) = request.card.kind {
            let message: String
            switch answer {
            case .approvePlan: message = "[Approved] \(plan.title)"
            case .revisePlan(let feedback): message = feedback
            default: throw ProviderConnectionError.invalidResponse
            }
            requests[id] = nil; order.removeAll { $0 == id }
            try await sendPrompt(message)
            return .accepted
        }
        guard Self.isOpen(step: request.step, conversation: request.conversation, tool: request.tool, log: log()) else {
            requests[id] = nil; order.removeAll { $0 == id }; return .alreadyAnswered
        }
        guard let current = await screen(session.id) else { throw ProviderConnectionError.disconnected }
        let options = Self.options(in: current)
        var keys = ""
        switch request.card.kind {
        case .permission(let permission):
            guard current.contains(permission.summary) || current.contains(request.tool) else { throw ProviderConnectionError.rejected("The terminal dialog changed. Try again.") }
            if case .denyAndStop = answer { send(Data([0x1B])); return .accepted }
            let choice: (key: String, label: String, isHighlighted: Bool)?
            switch answer {
            case .allow, .allowWithNote: choice = options.first { $0.label.hasPrefix("Yes") && !$0.label.localizedCaseInsensitiveContains("always") }
            case .alwaysAllow: choice = options.first { $0.label.localizedCaseInsensitiveContains("always") && $0.label.localizedCaseInsensitiveContains("conversation") && !$0.label.localizedCaseInsensitiveContains("persist") }
            case .deny, .denyWithNote: choice = options.first { $0.label.hasPrefix("No") }
            default: throw ProviderConnectionError.invalidResponse
            }
            guard let choice else { throw ProviderConnectionError.rejected("This dialog doesn't offer that action.") }
            if case .allowWithNote(let note) = answer { try sendNote(note, choice: choice, options: options); return .accepted }
            if case .denyWithNote(let note) = answer { try sendNote(note, choice: choice, options: options); return .accepted }
            keys = choice.key
        case .question(let steps):
            guard case .questionAnswers(let answers) = answer, let step = steps.first, let value = answers.first(where: { $0.stepID == step.id }), current.contains(step.prompt) else { throw ProviderConnectionError.rejected("The question changed. Try again.") }
            for label in value.selected {
                guard let option = options.first(where: { $0.label == label || $0.label.hasPrefix(label + " ") }) else { throw ProviderConnectionError.rejected("The question options changed.") }
                keys += option.key
            }
            if let other = value.other, !other.isEmpty {
                guard let writeIn = options.first(where: { $0.label.localizedCaseInsensitiveContains("write-in") }) else { throw ProviderConnectionError.rejected("This question has no write-in option.") }
                keys += writeIn.key + "\u{1B}[200~" + other + "\u{1B}[201~\r"
            } else if step.allowsMultiple { keys += "\r" }
            guard !keys.isEmpty else { throw ProviderConnectionError.invalidResponse }
        default: throw ProviderConnectionError.invalidResponse
        }
        // Last lifetime guard directly before writing: a Mac answer must not
        // send these digits into the ordinary composer.
        guard Self.isOpen(step: request.step, conversation: request.conversation, tool: request.tool, log: log()) else { return .alreadyAnswered }
        send(Data(keys.utf8))
        return .accepted
    }

    private func sendNote(_ note: String, choice: (key: String, label: String, isHighlighted: Bool), options: [(key: String, label: String, isHighlighted: Bool)]) throws {
        guard let current = options.first(where: \.isHighlighted), let from = Int(current.key), let to = Int(choice.key) else { throw ProviderConnectionError.rejected("The highlighted option isn't available.") }
        let arrow = to >= from ? "\u{1B}[B" : "\u{1B}[A"
        send(Data((String(repeating: arrow, count: abs(to - from)) + "\t\u{1B}[200~" + note + "\u{1B}[201~\r").utf8))
    }

    func sendPrompt(_ text: String) async throws {
        guard pending.isEmpty else { throw ProviderConnectionError.rejected("Answer the open dialog first.") }
        guard let current = await screen(session.id), !current.contains("Write-in..."), !current.contains("Persist") else { throw ProviderConnectionError.rejected("Answer the terminal dialog first.") }
        if session.status == .working {
            let file = URL(fileURLWithPath: eventsURL.path + ".queue")
            var payload = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
            var steps = payload["injectSteps"] as? [[String: Any]] ?? []
            steps.append(["userMessage": text]); payload["injectSteps"] = steps
            try JSONSerialization.data(withJSONObject: payload).write(to: file, options: .atomic)
        } else {
            // Kill/yank preserves the current Mac draft around the sent prompt.
            send(Data(("\u{01}\u{0B}\u{1B}[200~" + text + "\u{1B}[201~\r\u{19}").utf8))
        }
    }

    func stop() async throws { transcript.isStopping = true; send(Data([0x1B])) }
    func close() { }
}
