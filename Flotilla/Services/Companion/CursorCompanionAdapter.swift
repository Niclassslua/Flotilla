import Foundation
import SessionKit
import CompanionKit
import HooksKit

/// Cursor Agent CLI companion control: interactive TUI stays in tmux; the
/// phone answers via the blocking hook bridge (same socket as Claude).
@MainActor
final class CursorCompanionAdapter: CompanionSessionAdapter {
    var session: Session
    private let bridge: ClaudePermissionBridge
    private let events: URL
    private let screen: (UUID) async -> String?
    private let send: (Data) -> Void
    /// tmux-backed delivery (`AppStore.deliverMessage`): the only path
    /// confirmed to actually *submit* — a raw PTY write types the text into
    /// the composer but the TUI treats the trailing `\r` in the same bulk
    /// write as paste content, so it never submits (see
    /// `TmuxGoalDelivering`'s docstring).
    private let deliver: (String) async throws -> Void
    private var consumed = 0
    private(set) var transcript = SessionTranscript()
    var pending: [PendingInteraction] { bridge.pending(for: session.id) }

    init(
        session: Session,
        bridge: ClaudePermissionBridge,
        support: URL,
        screen: @escaping (UUID) async -> String?,
        send: @escaping (Data) -> Void,
        deliver: @escaping (String) async throws -> Void
    ) {
        self.session = session
        self.bridge = bridge
        events = HookConfigurationWriter.eventFilePath(for: session.id, supportDirectory: support)
        self.screen = screen
        self.send = send
        self.deliver = deliver
    }

    func refresh() async throws {
        guard let data = try? Data(contentsOf: events) else { return }
        if data.count < consumed { consumed = 0 }
        let tail = data.dropFirst(consumed)
        guard let end = tail.lastIndex(of: 10) else { return }
        let complete = tail[...end]
        consumed += complete.count
        for line in String(decoding: complete, as: UTF8.self).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let event = object["hook_event_name"] as? String
            switch event {
            case "postToolUse", "PostToolUse":
                let payload = object["payload"] as? [String: Any] ?? object
                bridge.retractCompleted(
                    sessionID: session.id,
                    toolUseID: payload["tool_use_id"] as? String ?? object["tool_use_id"] as? String
                )
            case "sessionEnd", "stop", "Stop":
                transcript.streamingText = nil
            default:
                break
            }
        }
    }

    func sendPrompt(_ text: String) async throws {
        guard pending.isEmpty else { throw ProviderConnectionError.rejected("Answer the open dialog first.") }
        if let current = await screen(session.id) {
            let blocked = current.contains("Run") && current.contains("Skip")
                || current.contains("Allow") && current.contains("Reject")
                || current.contains("Esc to cancel")
            if blocked { throw ProviderConnectionError.rejected("Answer the terminal dialog first.") }
            // Cursor has no draft stash (Ctrl-S types a literal "s"), and
            // anything already in the composer would be sent glued to the
            // phone's prompt.
            if Self.composerDraft(in: current) != nil {
                throw ProviderConnectionError.rejected("Send or clear the unsent text in the Mac terminal first.")
            }
        }
        try await deliver(text)
    }

    /// The text typed into Cursor's composer — the last `→` line on screen —
    /// or `nil` when it only shows its placeholder.
    static func composerDraft(in screen: String) -> String? {
        guard let line = screen.split(separator: "\n").last(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("→ ")
        }) else { return nil }
        let text = line.trimmingCharacters(in: .whitespaces).dropFirst(2)
            .trimmingCharacters(in: .whitespaces)
        let placeholders = ["Add a follow-up", "Plan, search, build anything"]
        return text.isEmpty || placeholders.contains(where: text.hasPrefix) ? nil : text
    }

    func stop() async throws {
        if bridge.denyAndStop(sessionID: session.id) {
            // Deny already returned to the hook; still Escape to cancel the turn.
            send(Data([0x1B]))
            return
        }
        send(Data([0x1B]))
    }

    func answer(_ id: UUID, with answer: InteractionAnswer) async throws -> AnswerOutcome {
        try await refresh()
        return bridge.answer(sessionID: session.id, interactionID: id, with: answer)
    }

    func close() {
        bridge.clearAlwaysAllow(sessionID: session.id)
    }
}
