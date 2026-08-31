import Foundation
import SessionKit

/// Tails the JSONL file `HookConfigurationWriter` points a launched agent's
/// hooks at, and emits the status and waiting reason each event implies.
///
/// Same `AsyncStream<SessionStatusObservation>` shape as
/// `SessionScreenMonitor`, so
/// `HookCoordinator` can run this alongside the screen monitor with no
/// change to how either stream is consumed — see `HookCoordinator.observe`.
/// Strictly observational, matching HooksKit's module-wide constraint: this
/// type only ever produces a status, it never writes to or terminates the
/// session it's watching.
public final class HookEventReceiver: @unchecked Sendable {
    private let filePath: URL
    private let agent: AgentKind
    private let pollInterval: Duration
    private let continuation: AsyncStream<SessionStatusObservation>.Continuation
    public let observationStream: AsyncStream<SessionStatusObservation>
    private let taskLock = NSLock()
    private var task: Task<Void, Never>?

    public init(filePath: URL, agent: AgentKind, pollInterval: Duration = .milliseconds(400)) {
        self.filePath = filePath
        self.agent = agent
        self.pollInterval = pollInterval
        var continuation: AsyncStream<SessionStatusObservation>.Continuation!
        self.observationStream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func start() {
        taskLock.lock()
        defer { taskLock.unlock() }
        guard task == nil else { return }
        let filePath = self.filePath
        let agent = self.agent
        let pollInterval = self.pollInterval
        let continuation = self.continuation

        task = Task {
            var readOffset: UInt64 = 0
            var fileIdentity: UInt64?
            var pendingData = Data()
            while !Task.isCancelled {
                if let handle = try? FileHandle(forReadingFrom: filePath) {
                    defer { try? handle.close() }
                    let attributes = try? FileManager.default.attributesOfItem(atPath: filePath.path)
                    let currentIdentity = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
                    let endOffset = (try? handle.seekToEnd()) ?? 0
                    if fileIdentity != currentIdentity || endOffset < readOffset {
                        // Atomic replacement and truncation both start a new
                        // event-file generation. Identity matters because a
                        // replacement can regrow past the old offset between
                        // polls, which a size-only check would miss.
                        fileIdentity = currentIdentity
                        readOffset = 0
                        pendingData.removeAll(keepingCapacity: true)
                    }
                    if endOffset >= readOffset {
                        try? handle.seek(toOffset: readOffset)
                        if let data = try? handle.readToEnd(), !data.isEmpty {
                            readOffset += UInt64(data.count)
                            pendingData.append(data)
                            while let newlineIndex = pendingData.firstIndex(of: 0x0A) {
                                let lineData = Data(pendingData[..<newlineIndex])
                                pendingData.removeSubrange(...newlineIndex)
                                guard !lineData.isEmpty,
                                      let line = String(data: lineData, encoding: .utf8) else { continue }
                                if let observation = Self.observation(forLine: line, agent: agent) {
                                    continuation.yield(observation)
                                }
                            }
                        }
                    }
                }
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    public func stop() {
        taskLock.lock()
        let taskToCancel = task
        task = nil
        taskLock.unlock()
        taskToCancel?.cancel()
    }

    deinit {
        task?.cancel()
        continuation.finish()
    }

    static func observation(forLine line: String, agent: AgentKind) -> SessionStatusObservation? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        switch agent {
        case .claudeCode:
            guard let eventName = object["hook_event_name"] as? String else { return nil }
            switch eventName {
            case "Notification":
                switch (object["notification_type"] as? String)?.lowercased() {
                case "idle_prompt":
                    // Claude emits this after a completed turn. It means the
                    // composer is free, not that Claude is blocked mid-turn.
                    return SessionStatusObservation(.readyForReview, cause: "hook: Notification/idle_prompt")
                case "permission_prompt":
                    let message = (object["message"] as? String)?.lowercased() ?? ""
                    let reason: SessionWaitingReason = message.contains("plan") ? .planApproval : .permission
                    return SessionStatusObservation(
                        .waitingForInput,
                        waitingReason: reason,
                        cause: "hook: Notification/permission_prompt"
                    )
                case "elicitation_dialog":
                    return SessionStatusObservation(
                        .waitingForInput,
                        waitingReason: .question,
                        cause: "hook: Notification/elicitation_dialog"
                    )
                default:
                    return nil
                }
            case "PreToolUse":
                let tool = object["tool_name"] as? String
                return Self.claudeInteractiveObservation(toolName: tool, event: "PreToolUse")
                    ?? SessionStatusObservation(.working, cause: "hook: PreToolUse \(Self.toolLabel(tool))")
            case "PermissionRequest":
                let tool = object["tool_name"] as? String
                return Self.claudeInteractiveObservation(toolName: tool, event: "PermissionRequest")
                    ?? SessionStatusObservation(
                        .waitingForInput,
                        waitingReason: .permission,
                        cause: "hook: PermissionRequest \(Self.toolLabel(tool))"
                    )
            case "Stop": return SessionStatusObservation(.readyForReview, cause: "hook: Stop")
            case "PostToolUse":
                return SessionStatusObservation(
                    .working,
                    cause: "hook: PostToolUse \(Self.toolLabel(object["tool_name"] as? String))"
                )
            default: return nil
            }
        case .antigravity:
            guard let eventName = object["event"] as? String,
                  let payload = object["payload"] as? [String: Any] else { return nil }
            switch eventName {
            case "PreToolUse":
                let toolName = (payload["toolCall"] as? [String: Any])?["name"] as? String
                return toolName == "ask_question"
                    ? SessionStatusObservation(
                        .waitingForInput,
                        waitingReason: .question,
                        cause: "hook: PreToolUse ask_question"
                      )
                    : SessionStatusObservation(.working, cause: "hook: PreToolUse \(Self.toolLabel(toolName))")
            case "PostToolUse":
                if Self.antigravityRequestsPlanFeedback(payload) {
                    return SessionStatusObservation(
                        .waitingForInput,
                        waitingReason: .planApproval,
                        cause: "hook: PostToolUse write_to_file with RequestFeedback"
                    )
                }
                return SessionStatusObservation(
                    .working,
                    cause: "hook: PostToolUse \(Self.toolLabel((payload["toolCall"] as? [String: Any])?["name"] as? String))"
                )
            case "Stop":
                return (payload["fullyIdle"] as? Bool) == true
                    ? SessionStatusObservation(.readyForReview, cause: "hook: Stop fullyIdle=true")
                    : nil
            default:
                return nil
            }
        case .codexCLI:
            // Codex provides a self-describing hook_event_name in every
            // command-hook payload. PermissionRequest is observational: the
            // wrapper exits successfully without output, leaving Codex's
            // normal approval prompt intact.
            guard let eventName = object["hook_event_name"] as? String else { return nil }
            switch eventName {
            case "PreToolUse":
                let toolName = (object["tool_name"] as? String)?.lowercased()
                if toolName == "request_user_input" || toolName == "askuserquestion" {
                    return SessionStatusObservation(
                        .waitingForInput,
                        waitingReason: .question,
                        cause: "hook: PreToolUse \(Self.toolLabel(toolName))"
                    )
                }
                return SessionStatusObservation(.working, cause: "hook: PreToolUse \(Self.toolLabel(toolName))")
            case "PostToolUse":
                return SessionStatusObservation(
                    .working,
                    cause: "hook: PostToolUse \(Self.toolLabel(object["tool_name"] as? String))"
                )
            case "Stop":
                // Codex renders a finalized Plan-mode response specially and
                // reports `last_assistant_message: null` on the Stop hook.
                if object["last_assistant_message"] is NSNull {
                    return SessionStatusObservation(
                        .waitingForInput,
                        waitingReason: .planApproval,
                        cause: "hook: Stop with last_assistant_message=null (plan mode)"
                    )
                }
                return SessionStatusObservation(.readyForReview, cause: "hook: Stop")
            case "PermissionRequest":
                return SessionStatusObservation(
                    .waitingForInput,
                    waitingReason: .permission,
                    cause: "hook: PermissionRequest"
                )
            default: return nil
            }
        case .openCode:
            // Written by the generated stable project plugin (see
            // HookConfigurationWriter.openCodePluginContents) as a flat
            // {"event": "<name>"} line — no nested payload needed for any
            // of these mappings. session.idle is a naming trap: it means
            // "turn ended, composer free" (Flotilla's .readyForReview).
            guard let eventName = object["event"] as? String else { return nil }
            switch eventName {
            case "tool.execute.after":
                return SessionStatusObservation(.working, cause: "hook: tool.execute.after")
            case "session.idle":
                return SessionStatusObservation(.readyForReview, cause: "hook: session.idle")
            case "permission.asked":
                return SessionStatusObservation(
                    .waitingForInput,
                    waitingReason: .permission,
                    cause: "hook: permission.asked"
                )
            case "question.asked":
                return SessionStatusObservation(
                    .waitingForInput,
                    waitingReason: .question,
                    cause: "hook: question.asked"
                )
            default: return nil
            }
        }
    }

    private static func claudeInteractiveObservation(
        toolName: String?,
        event: String
    ) -> SessionStatusObservation? {
        switch toolName?.lowercased() {
        case "exitplanmode":
            return SessionStatusObservation(
                .waitingForInput,
                waitingReason: .planApproval,
                cause: "hook: \(event) ExitPlanMode"
            )
        case "askuserquestion":
            return SessionStatusObservation(
                .waitingForInput,
                waitingReason: .question,
                cause: "hook: \(event) AskUserQuestion"
            )
        default:
            return nil
        }
    }

    /// The tool name a hook event carried, or a placeholder — hook payloads
    /// omit it for non-tool events, and a log line saying which is which is
    /// worth more than one that silently drops the field.
    private static func toolLabel(_ toolName: String?) -> String {
        toolName.map { "tool=\($0)" } ?? "tool=unknown"
    }

    private static func antigravityRequestsPlanFeedback(_ payload: [String: Any]) -> Bool {
        guard let toolCall = payload["toolCall"] as? [String: Any],
              toolCall["name"] as? String == "write_to_file" else { return false }
        let arguments = (toolCall["args"] as? [String: Any]) ?? (payload["args"] as? [String: Any])
        let metadata = arguments?["ArtifactMetadata"] as? [String: Any]
        return metadata?["RequestFeedback"] as? Bool == true
    }
}
