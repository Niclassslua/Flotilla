import Foundation
import SessionKit
import CompanionKit
import HooksKit

@MainActor
final class ClaudeCompanionAdapter: CompanionSessionAdapter {
    var session: Session
    private let bridge: ClaudePermissionBridge
    private let events: URL
    private let screen: (UUID) async -> String?
    private let send: (Data) -> Void
    private var consumed = 0
    private var batches: [Int: String] = [:]
    private(set) var transcript = SessionTranscript()
    var pending: [PendingInteraction] { bridge.pending(for: session.id) }

    init(session: Session, bridge: ClaudePermissionBridge, support: URL, screen: @escaping (UUID) async -> String?, send: @escaping (Data) -> Void) {
        self.session = session; self.bridge = bridge
        events = HookConfigurationWriter.eventFilePath(for: session.id, supportDirectory: support)
        self.screen = screen; self.send = send
    }

    func refresh() async throws {
        guard let data = try? Data(contentsOf: events) else { return }
        if data.count < consumed { consumed = 0 }
        let tail = data.dropFirst(consumed)
        guard let end = tail.lastIndex(of: 10) else { return }
        let complete = tail[...end]; consumed += complete.count
        for line in String(decoding: complete, as: UTF8.self).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let event = object["hook_event_name"] as? String else { continue }
            switch event {
            case "MessageDisplay":
                let index = object["index"] as? Int ?? batches.count
                let text = object["text"] as? String ?? object["message"] as? String ?? ""
                batches[index] = text
                transcript.streamingText = batches.keys.sorted().compactMap { batches[$0] }.joined()
                if object["final"] as? Bool == true { batches.removeAll(); transcript.streamingText = nil }
            case "StopFailure": transcript.append(.turnFailed(message: object["last_assistant_message"] as? String ?? object["error"] as? String ?? "Claude turn failed."))
            case "PostToolUse", "PostToolUseFailure":
                bridge.retractCompleted(sessionID: session.id, toolUseID: object["tool_use_id"] as? String)
            case "UserPromptSubmit", "Stop": batches.removeAll(); transcript.streamingText = nil
            default: break
            }
        }
    }

    func sendPrompt(_ text: String) async throws {
        guard pending.isEmpty else { throw ProviderConnectionError.rejected("Answer the open dialog first.") }
        guard let current = await screen(session.id), !current.contains("Esc to cancel"), !current.contains("Enter to select"), !current.contains("Would you like to") else { throw ProviderConnectionError.rejected("Answer the terminal dialog first.") }
        // Ctrl-S stashes a genuine Mac draft; Claude ignores it for a dim
        // suggestion. Native queueing handles prompts submitted mid-turn.
        send(Data(("\u{13}\u{1B}[200~" + text + "\u{1B}[201~\r").utf8))
    }

    func stop() async throws {
        if !bridge.denyAndStop(sessionID: session.id) { send(Data([0x1B])) }
    }

    func answer(_ id: UUID, with answer: InteractionAnswer) async throws -> AnswerOutcome {
        try await refresh()
        return bridge.answer(sessionID: session.id, interactionID: id, with: answer)
    }

    func close() { }
}
