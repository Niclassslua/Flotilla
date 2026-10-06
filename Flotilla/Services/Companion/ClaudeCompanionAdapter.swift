import Foundation
import SessionKit
import CompanionKit
import HooksKit

@MainActor
final class ClaudeCompanionAdapter: CompanionSessionAdapter {
    var session: Session
    private let bridge: ClaudePermissionBridge
    private let events: URL
    private let display: URL
    private let screen: (UUID) async -> String?
    private let send: (Data) -> Void
    private var consumed = 0
    private var displayConsumed = 0
    /// The message currently streaming, its chunks by `index`. Async hooks
    /// can land out of order, so chunks are placed rather than appended.
    private var streaming: (messageID: String, chunks: [Int: String])?
    /// Messages whose `final` chunk arrived; a straggling earlier chunk must
    /// not bring a finished message back as live text.
    private var finishedMessageIDs: [String] = []
    private(set) var transcript = SessionTranscript()
    var pending: [PendingInteraction] { bridge.pending(for: session.id) }

    init(session: Session, bridge: ClaudePermissionBridge, support: URL, screen: @escaping (UUID) async -> String?, send: @escaping (Data) -> Void) {
        self.session = session; self.bridge = bridge
        events = HookConfigurationWriter.eventFilePath(for: session.id, supportDirectory: support)
        display = HookConfigurationWriter.displayFilePath(for: session.id, supportDirectory: support)
        self.screen = screen; self.send = send
    }

    func refresh() async throws {
        // Text first: a `Stop` or `StopFailure` read in the same tick ends
        // whatever was streaming, including a message cut off before `final`.
        for object in Self.newRecords(in: display, consumed: &displayConsumed) {
            receiveDisplay(object)
        }
        for object in Self.newRecords(in: events, consumed: &consumed) {
            switch object["hook_event_name"] as? String {
            case "StopFailure":
                transcript.append(.turnFailed(message: Self.failureMessage(object)))
                endStreaming()
            case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
                bridge.retractCompleted(sessionID: session.id, toolUseID: object["tool_use_id"] as? String)
            case "UserPromptSubmit", "Stop":
                endStreaming()
            default: break
            }
        }
    }

    /// One `MessageDisplay` chunk: `message_id`, `index`, `delta`, `final`.
    private func receiveDisplay(_ object: [String: Any]) {
        guard object["hook_event_name"] as? String == "MessageDisplay",
              let messageID = object["message_id"] as? String,
              !finishedMessageIDs.contains(messageID) else { return }
        if object["final"] as? Bool == true {
            markFinished(messageID)
            endStreaming()
            return
        }
        var chunks = (streaming?.messageID == messageID ? streaming?.chunks : nil) ?? [:]
        chunks[object["index"] as? Int ?? chunks.count] = object["delta"] as? String ?? ""
        streaming = (messageID, chunks)
        transcript.streamingText = chunks.keys.sorted().compactMap { chunks[$0] }.joined()
    }

    /// A message that stops streaming without `final` (an interrupt, an API
    /// error) is finished too; its stragglers must not revive it.
    private func endStreaming() {
        if let messageID = streaming?.messageID { markFinished(messageID) }
        streaming = nil
        transcript.streamingText = nil
    }

    private func markFinished(_ messageID: String) {
        guard !finishedMessageIDs.contains(messageID) else { return }
        finishedMessageIDs.append(messageID)
        if finishedMessageIDs.count > 32 { finishedMessageIDs.removeFirst() }
    }

    /// `StopFailure` names the error type in `error` (`rate_limit`, …) and
    /// says what happened in `error_details`.
    nonisolated static func failureMessage(_ object: [String: Any]) -> String {
        let details = (object["error_details"] as? String) ?? (object["last_assistant_message"] as? String)
        let type = (object["error"] as? String)?.replacingOccurrences(of: "_", with: " ")
        switch (type, details) {
        case let (type?, details?): return "Claude stopped (\(type)): \(details)"
        case let (nil, details?): return "Claude stopped: \(details)"
        case let (type?, nil): return "Claude stopped (\(type))."
        case (nil, nil): return "Claude turn failed."
        }
    }

    /// Complete JSONL records appended since `consumed`. A file that shrank
    /// was truncated by a relaunch and is read again from the start.
    private static func newRecords(in file: URL, consumed: inout Int) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        if data.count < consumed { consumed = 0 }
        let tail = data.dropFirst(consumed)
        guard let end = tail.lastIndex(of: 10) else { return [] }
        let complete = tail[...end]
        consumed += complete.count
        return String(decoding: complete, as: UTF8.self).split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
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
