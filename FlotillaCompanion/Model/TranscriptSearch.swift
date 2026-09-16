import Foundation

/// One hit while searching the currently rendered transcript.
struct TranscriptSearchMatch: Identifiable, Equatable {
    let id: String
    /// The `TranscriptItem` to scroll to — a tool match's item is its group.
    let itemID: String
    /// Set when the match lives inside a tool group, so it can be expanded.
    let groupID: String?
    let excerpt: String
}

/// Searches only what's already loaded: user/assistant text, system notes,
/// failed-turn messages, and tool call input/output. Never fetches older
/// history.
enum TranscriptSearch {
    static func matches(in items: [TranscriptItem], query: String) -> [TranscriptSearchMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        var results: [TranscriptSearchMatch] = []
        for item in items {
            switch item {
            case .user(let id, let text), .assistant(let id, let text), .system(let id, let text):
                if let excerpt = excerpt(in: text, matching: needle) {
                    results.append(TranscriptSearchMatch(id: id, itemID: id, groupID: nil, excerpt: excerpt))
                }
            case .failed(let id, let message):
                if let excerpt = excerpt(in: message, matching: needle) {
                    results.append(TranscriptSearchMatch(id: id, itemID: id, groupID: nil, excerpt: excerpt))
                }
            case .toolGroup(let groupID, let calls):
                for call in calls {
                    if let excerpt = excerpt(in: call.tool, matching: needle) {
                        results.append(TranscriptSearchMatch(id: "\(groupID)#\(call.id)#tool", itemID: groupID, groupID: groupID, excerpt: excerpt))
                    }
                    for key in call.input.keys.sorted() {
                        guard let value = call.input[key], let excerpt = excerpt(in: value, matching: needle) else { continue }
                        results.append(TranscriptSearchMatch(id: "\(groupID)#\(call.id)#input#\(key)", itemID: groupID, groupID: groupID, excerpt: excerpt))
                    }
                    if let output = call.output, let excerpt = excerpt(in: output, matching: needle) {
                        results.append(TranscriptSearchMatch(id: "\(groupID)#\(call.id)#output", itemID: groupID, groupID: groupID, excerpt: excerpt))
                    }
                }
            case .image, .handoff, .resolved:
                continue
            }
        }
        return results
    }

    private static let contextRadius = 40

    private static func excerpt(in text: String, matching needle: String) -> String? {
        guard let range = text.range(of: needle, options: .caseInsensitive) else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -contextRadius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: contextRadius, limitedBy: text.endIndex) ?? text.endIndex
        var excerpt = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if start != text.startIndex { excerpt = "…" + excerpt }
        if end != text.endIndex { excerpt += "…" }
        return excerpt
    }
}
