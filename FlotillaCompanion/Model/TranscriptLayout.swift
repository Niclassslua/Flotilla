import Foundation
import SessionKit
import TranscriptKit

/// One row of the rendered transcript.
enum TranscriptItem: Identifiable {
    case user(id: UUID, text: String)
    case assistant(id: UUID, text: String)
    case toolGroup(id: UUID, calls: [ToolCall])
    case system(id: UUID, text: String)
    case handoff(id: UUID, from: AgentKind, to: AgentKind)
    case resolved(id: UUID, text: String, isPositive: Bool)
    case failed(id: UUID, message: String)

    var id: UUID {
        switch self {
        case .user(let id, _), .assistant(let id, _), .toolGroup(let id, _), .system(let id, _),
             .handoff(let id, _, _), .resolved(let id, _, _), .failed(let id, _):
            id
        }
    }
}

/// A `toolUse` with its `toolResult`, if one has arrived.
struct ToolCall: Identifiable, Sendable {
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
        input["command"] ?? input["file_path"] ?? input["path"] ?? input["pattern"] ?? input["url"] ?? input["query"]
    }

    /// A file the call touched, for opening the file viewer or diff.
    var filePath: String? {
        input["file_path"] ?? input["path"]
    }

    var isEdit: Bool { ["Edit", "Write", "MultiEdit", "apply_patch"].contains(tool) }

    var systemImage: String {
        switch tool {
        case "Bash", "shell": "terminal"
        case "Edit", "MultiEdit", "apply_patch": "pencil"
        case "Write": "square.and.pencil"
        case "Read": "doc.text"
        case "Grep", "Glob": "magnifyingglass"
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
            if case .entry(.toolResult(let useID, let output, let isError, _)) = event.content {
                results[useID] = (output, isError)
            }
        }

        var items: [TranscriptItem] = []
        var group: (id: UUID, calls: [ToolCall])?

        func flush() {
            if let current = group { items.append(.toolGroup(id: current.id, calls: current.calls)) }
            group = nil
        }

        for event in events {
            switch event.content {
            case .entry(let entry):
                switch entry {
                case .toolUse(let useID, let tool, let input, let timestamp):
                    let result = results[useID]
                    let call = ToolCall(
                        id: useID,
                        tool: tool,
                        input: decodeInput(input),
                        output: result?.0,
                        isError: result?.1 ?? false,
                        startedAt: timestamp
                    )
                    if group == nil { group = (event.id, []) }
                    group?.calls.append(call)
                case .toolResult, .image:
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
                case .handoffMarker(let from, let to, _, _):
                    flush()
                    items.append(.handoff(id: event.id, from: from, to: to))
                }
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

    /// The call still waiting for its result, which the working indicator names.
    static func inFlightCall(in events: [TranscriptEvent]) -> ToolCall? {
        guard case .toolGroup(_, let calls)? = items(from: events).last else { return nil }
        return calls.last(where: \.isRunning)
    }

    private static func decodeInput(_ data: Data) -> [String: String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.compactMapValues { value in
            switch value {
            case let string as String: string
            case let number as NSNumber: number.stringValue
            default: nil
            }
        }
    }
}
