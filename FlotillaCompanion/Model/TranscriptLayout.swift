import Foundation
import SessionKit
import CompanionKit

/// One row of the rendered transcript.
enum TranscriptItem: Identifiable, Equatable {
    case user(id: String, text: String)
    case assistant(id: String, text: String)
    case toolGroup(id: String, calls: [ToolCall])
    case system(id: String, text: String)
    case image(id: String, mimeType: String, base64: String, filename: String?)
    case handoff(id: String, from: AgentKind, to: AgentKind)
    case resolved(id: String, text: String, isPositive: Bool)
    case failed(id: String, message: String)

    var id: String {
        switch self {
        case .user(let id, _), .assistant(let id, _), .toolGroup(let id, _), .system(let id, _),
             .image(let id, _, _, _), .handoff(let id, _, _), .resolved(let id, _, _), .failed(let id, _):
            id
        }
    }
}

/// A `toolUse` with its `toolResult`, if one has arrived.
struct ToolCall: Identifiable, Sendable, Equatable {
    let id: String
    var tool: String
    var input: [String: String]
    var output: String?
    var isError: Bool
    var startedAt: Date

    var isRunning: Bool { output == nil }

    /// `Bash · npm test`, `Edit · Sources/App.swift`.
    var summary: String {
        guard let subject else { return tool }
        return "\(tool) · \(subject)"
    }

    /// The command, path, or pattern the call acts on.
    var subject: String? {
        if let path = input["file_path"] ?? input["path"] {
            return (path as NSString).lastPathComponent
        }
        return input["command"] ?? input["cmd"] ?? input["pattern"] ?? input["url"] ?? input["query"] ?? input["description"]
    }

    /// A file the call touched, for opening the file viewer or diff.
    var filePath: String? {
        input["file_path"] ?? input["path"]
    }

    var isEdit: Bool { ["Edit", "Write", "MultiEdit", "apply_patch", "edit", "write", "write_to_file", "replace_file_content"].contains(tool) }

    var systemImage: String {
        switch tool {
        case "Bash", "shell", "run_command", "exec_command": "terminal"
        case "Edit", "MultiEdit", "apply_patch", "edit", "replace_file_content": "pencil"
        case "Write", "write", "write_to_file": "square.and.pencil"
        case "Read", "read", "view_file": "doc.text"
        case "Grep", "Glob", "grep", "glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Task": "person.2"
        default: "wrench.and.screwdriver"
        }
    }
}

enum TranscriptLayout {
    /// Pairs tool calls and collapses consecutive ones into groups.
    ///
    /// Pairs by id directly rather than through `ToolCallPairing`: that type
    /// synthesizes a result for any unanswered call, which is right for a
    /// handoff and wrong here — an unanswered call is the one still running.
    static func items(from events: [TranscriptEvent]) -> [TranscriptItem] {
        var results: [String: (String, Bool)] = [:]
        for event in events {
            if case .toolResult(let useID, let output, let isError, _) = event.content {
                results[useID] = (output, isError)
            }
        }

        var items: [TranscriptItem] = []
        var group: (id: String, calls: [ToolCall])?

        func flush() {
            if let current = group { items.append(.toolGroup(id: current.id, calls: current.calls)) }
            group = nil
        }

        for event in events {
            switch event.content {
            case .toolUse(let useID, let tool, let input, let timestamp):
                let result = results[useID]
                let call = ToolCall(
                    id: useID,
                    tool: tool,
                    input: input,
                    output: result?.0,
                    isError: result?.1 ?? false,
                    startedAt: timestamp
                )
                if group == nil { group = (event.id, []) }
                group?.calls.append(call)
            case .toolResult:
                continue
            case .userMessage(let text, _):
                flush()
                items.append(.user(id: event.id, text: text))
            case .assistantMessage(let text, _):
                flush()
                items.append(.assistant(id: event.id, text: text))
            case .systemNote(let text, _):
                flush()
                items.append(.system(id: event.id, text: text))
            case .image(let mimeType, let base64, let filename, _):
                flush()
                items.append(.image(id: event.id, mimeType: mimeType, base64: base64, filename: filename))
            case .handoff(let from, let to, _):
                flush()
                items.append(.handoff(id: event.id, from: from, to: to))
            case .resolvedInteraction(let text, let isPositive):
                flush()
                items.append(.resolved(id: event.id, text: text, isPositive: isPositive))
            case .turnFailed(let message):
                flush()
                items.append(.failed(id: event.id, message: message))
            }
        }
        flush()
        return items
    }

    /// The call still waiting for its result, looking at precomputed items in O(1).
    static func inFlightCall(in items: [TranscriptItem]) -> ToolCall? {
        guard case .toolGroup(_, let calls)? = items.last else { return nil }
        return calls.last(where: \.isRunning)
    }

    /// The call still waiting for its result, which the working indicator names.
    static func inFlightCall(in events: [TranscriptEvent]) -> ToolCall? {
        inFlightCall(in: items(from: events))
    }
}
