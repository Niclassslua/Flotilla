import Foundation

/// A question an agent put to the user, normalized across providers.
struct TranscriptQuestion: Identifiable, Sendable, Equatable {
    struct Option: Sendable, Equatable {
        var label: String
        var description: String?
        var isRecommended: Bool
    }

    let id: String
    var header: String?
    var prompt: String
    var options: [Option]
    /// The chosen labels, or the text the user typed instead.
    var answers: [String] = []
    var note: String?

    func option(forAnswer answer: String) -> Option? {
        options.first { $0.label == answer }
    }

    var otherOptions: [Option] {
        options.filter { !answers.contains($0.label) }
    }
}

/// Reads each provider's question tool. Every one takes a `questions` array
/// (a JSON string by the time it reaches `ToolCall.input`) but they name the
/// fields differently and report the answer in different shapes:
///
/// | Tool | Options | Answer in the result |
/// | --- | --- | --- |
/// | Claude `AskUserQuestion` | `{label, description}` | `"Q"="A", "Q2"="B"` sentence |
/// | OpenCode `question` | `{label, description}` | `"Q"="A"` sentence |
/// | Codex `request_user_input` | `{label, description}` | `{"answers":{id:{"answers":[…]}}}` |
/// | Cursor `AskQuestion` | `{id, label}`, `prompt` for the text | not recorded |
/// | Antigravity `ask_question` | plain strings | not decoded (see its FORMAT.md) |
enum TranscriptQuestions {
    static let tools: Set<String> = ["AskUserQuestion", "request_user_input", "question", "AskQuestion", "ask_question"]

    /// `nil` when `call` isn't a question or its input doesn't have the
    /// expected shape; it then renders as an ordinary tool call.
    static func parse(_ call: ToolCall) -> [TranscriptQuestion]? {
        guard tools.contains(call.tool),
              let data = call.input["questions"]?.data(using: .utf8),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }

        var questions: [TranscriptQuestion] = []
        var providerIDs: [String?] = []
        for entry in entries {
            guard let prompt = (entry["question"] ?? entry["prompt"]) as? String else { continue }
            let options = (entry["options"] as? [Any] ?? []).compactMap(option)
            questions.append(TranscriptQuestion(id: String(questions.count), header: entry["header"] as? String, prompt: prompt, options: options))
            providerIDs.append(entry["id"] as? String)
        }
        guard !questions.isEmpty else { return nil }
        guard let output = call.output, !call.isError else { return questions }

        if let answers = structuredAnswers(in: output) {
            for index in questions.indices {
                guard let id = providerIDs[index], let chosen = answers[id] else { continue }
                questions[index].answers = chosen.map { strippingRecommended($0).label }
            }
        } else {
            applySentenceAnswers(in: output, to: &questions)
        }
        return questions
    }

    /// The `expandedGroups` key for one question's other options.
    static func disclosureKey(rowID: String, question: TranscriptQuestion) -> String {
        "\(rowID)#\(question.id)"
    }

    private static func option(_ value: Any) -> TranscriptQuestion.Option? {
        let raw = (value as? String) ?? (value as? [String: Any])?["label"] as? String
        guard let raw else { return nil }
        let (label, isRecommended) = strippingRecommended(raw)
        let description = (value as? [String: Any])?["description"] as? String
        return .init(label: label, description: description?.isEmpty == false ? description : nil, isRecommended: isRecommended)
    }

    private static func strippingRecommended(_ raw: String) -> (label: String, isRecommended: Bool) {
        let label = raw.trimmingCharacters(in: .whitespaces)
        let anchors: [String.CompareOptions] = [[.anchored, .caseInsensitive], [.anchored, .caseInsensitive, .backwards]]
        for options in anchors {
            if let range = label.range(of: "(recommended)", options: options) {
                return (label.replacingCharacters(in: range, with: "").trimmingCharacters(in: .whitespaces), true)
            }
        }
        return (label, false)
    }

    /// Codex's `{"answers":{"<id>":{"answers":["label"]}}}`.
    private static func structuredAnswers(in output: String) -> [String: [String]]? {
        guard let data = output.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let answers = json["answers"] as? [String: Any] else { return nil }
        return answers.compactMapValues { ($0 as? [String: Any])?["answers"] as? [String] }
    }

    /// `… "Q"="A", "Q2"="B" user notes: why. You can now continue …`
    ///
    /// Answers are free text and aren't escaped, so this anchors on the exact
    /// question text from the input instead of on the quotes around values.
    private static func applySentenceAnswers(in output: String, to questions: inout [TranscriptQuestion]) {
        let marks = questions.indices
            .compactMap { index in output.range(of: "\"\(questions[index].prompt)\"=\"").map { (index, $0) } }
            .sorted { $0.1.lowerBound < $1.1.lowerBound }

        for (position, (index, marker)) in marks.enumerated() {
            let isLast = position == marks.count - 1
            var region = output[marker.upperBound..<(isLast ? output.endIndex : marks[position + 1].1.lowerBound)]
            if isLast, let tail = [". You can now continue", ". Read the answers"].compactMap({ region.range(of: $0, options: .backwards)?.lowerBound }).first {
                region = region[..<tail]
            }
            let end = ["\" selected preview:", "\" user notes: "].compactMap { region.range(of: $0)?.lowerBound }.min() ?? region.lastIndex(of: "\"")
            guard let end else { continue }

            questions[index].answers = split(String(region[..<end]), options: questions[index].options)
            if let notes = region.range(of: " user notes: ") {
                let note = region[notes.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespacesAndNewlines))
                questions[index].note = note.isEmpty ? nil : note
            }
        }
    }

    /// Multi-select answers arrive joined by `, `. Only split when every part
    /// is a known option, so a typed sentence with commas stays whole.
    private static func split(_ raw: String, options: [TranscriptQuestion.Option]) -> [String] {
        let labels = Set(options.map(\.label))
        let whole = strippingRecommended(raw).label
        if labels.contains(whole) { return [whole] }
        let parts = raw.components(separatedBy: ", ").map { strippingRecommended($0).label }
        return parts.allSatisfy(labels.contains) ? parts : [whole]
    }
}
