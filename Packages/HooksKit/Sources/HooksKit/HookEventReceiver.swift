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
    /// A permission ask, for Home's Top permissions widget. Separate from
    /// `observationStream` because one hook line can produce both a status
    /// observation and a permission event (a `PermissionRequest` is both
    /// "the session is now waiting" and "here's what it asked for").
    private let permissionContinuation: AsyncStream<HookPermissionRequestEvent>.Continuation
    public let permissionRequestStream: AsyncStream<HookPermissionRequestEvent>
    /// The provider's own id for the conversation the process is in now.
    /// Separate from status: `/clear` or a fork moves the process to a new
    /// conversation without changing what it is doing.
    private let identityContinuation: AsyncStream<HookSessionIdentityEvent>.Continuation
    public let sessionIdentityStream: AsyncStream<HookSessionIdentityEvent>
    private let taskLock = NSLock()
    private var task: Task<Void, Never>?

    public init(filePath: URL, agent: AgentKind, pollInterval: Duration = .milliseconds(400)) {
        self.filePath = filePath
        self.agent = agent
        self.pollInterval = pollInterval
        var continuation: AsyncStream<SessionStatusObservation>.Continuation!
        self.observationStream = AsyncStream { continuation = $0 }
        self.continuation = continuation
        var permissionContinuation: AsyncStream<HookPermissionRequestEvent>.Continuation!
        self.permissionRequestStream = AsyncStream { permissionContinuation = $0 }
        self.permissionContinuation = permissionContinuation
        var identityContinuation: AsyncStream<HookSessionIdentityEvent>.Continuation!
        self.sessionIdentityStream = AsyncStream { identityContinuation = $0 }
        self.identityContinuation = identityContinuation
    }

    public func start() {
        taskLock.lock()
        defer { taskLock.unlock() }
        guard task == nil else { return }
        let filePath = self.filePath
        let agent = self.agent
        let pollInterval = self.pollInterval
        let continuation = self.continuation
        let permissionContinuation = self.permissionContinuation
        let identityContinuation = self.identityContinuation

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
                                if let permission = Self.permissionRequestEvent(forLine: line, agent: agent) {
                                    permissionContinuation.yield(permission)
                                }
                                if let identity = Self.sessionIdentityEvent(forLine: line, agent: agent) {
                                    identityContinuation.yield(identity)
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
        permissionContinuation.finish()
        identityContinuation.finish()
    }

    static func observation(forLine line: String, agent: AgentKind) -> SessionStatusObservation? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let summary = payloadSummary(from: object, agent: agent)
        /// Appends the payload summary (when present) to a base cause string.
        let cause: (String) -> String = { base in
            summary.map { "\(base) | \($0)" } ?? base
        }

        switch agent {
        case .claudeCode:
            guard let eventName = object["hook_event_name"] as? String else { return nil }
            // Claude's own background helpers (title, recap, notifications)
            // run as agents with an `agent_id` but no `agent_type`, and keep
            // firing tool events after the turn's `Stop`. They say nothing
            // about the session; a real subagent always names its type.
            if object["agent_id"] is String,
               ((object["agent_type"] as? String) ?? "").isEmpty {
                return nil
            }
            switch eventName {
            case "Notification":
                let type = (object["notification_type"] as? String)?.lowercased() ?? ""
                switch type {
                case "idle_prompt":
                    // Claude emits this after a completed turn. It means the
                    // composer is free, not that Claude is blocked mid-turn.
                    return SessionStatusObservation(.readyForReview, cause: cause("hook: Notification/idle_prompt"))
                case "permission_prompt":
                    // 2.1.290 says "Claude needs your permission" for a plan
                    // too; the plan reason then comes from the
                    // `ExitPlanMode` hooks, which fire alongside.
                    let message = (object["message"] as? String)?.lowercased() ?? ""
                    let reason: SessionWaitingReason = message.contains("plan") ? .planApproval : .permission
                    return SessionStatusObservation(
                        .waitingForInput,
                        waitingReason: reason,
                        cause: cause("hook: Notification/permission_prompt")
                    )
                case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                    return SessionStatusObservation(
                        .waitingForInput,
                        waitingReason: .question,
                        cause: cause("hook: Notification/\(type)")
                    )
                case "elicitation_complete", "elicitation_response", "quota_auto_resume_fired":
                    return SessionStatusObservation(.working, cause: cause("hook: Notification/\(type)"))
                default:
                    // `auth_success`, `agent_completed` (a background agent,
                    // not the turn) and the quota bookkeeping subtypes.
                    return nil
                }
            case "UserPromptSubmit":
                // Fires for typed prompts and for turns Claude starts itself
                // (a background subagent handing back), before any tool runs —
                // the only signal for a turn spent thinking or writing.
                return SessionStatusObservation(.working, cause: cause("hook: UserPromptSubmit"))
            case "StopFailure":
                // The turn ended on an API error; `error` is its type.
                let type = (object["error"] as? String) ?? "unknown"
                return SessionStatusObservation(.readyForReview, cause: cause("hook: StopFailure \(type)"))
            case "PostToolUseFailure":
                if (object["is_interrupt"] as? Bool) == true {
                    // Esc during a tool ends the turn without a `Stop`.
                    return SessionStatusObservation(
                        .readyForReview,
                        cause: cause("hook: PostToolUseFailure interrupted \(Self.toolLabel(object["tool_name"] as? String))")
                    )
                }
                return SessionStatusObservation(
                    .working,
                    cause: cause("hook: PostToolUseFailure \(Self.toolLabel(object["tool_name"] as? String))")
                )
            case "PermissionDenied":
                // Auto mode refused a call; the model carries on without it.
                return SessionStatusObservation(
                    .working,
                    cause: cause("hook: PermissionDenied \(Self.toolLabel(object["tool_name"] as? String))")
                )
            case "PreCompact", "SubagentStart":
                return SessionStatusObservation(.working, cause: cause("hook: \(eventName)"))
            case "PostCompact":
                // `/compact` is its own command and ends with the composer
                // free; an automatic compaction happens inside a turn that
                // carries on.
                if (object["trigger"] as? String) == "manual" {
                    return SessionStatusObservation(.readyForReview, cause: cause("hook: PostCompact manual"))
                }
                return SessionStatusObservation(.working, cause: cause("hook: PostCompact auto"))
            case "PreToolUse":
                let tool = object["tool_name"] as? String
                return Self.claudeInteractiveObservation(toolName: tool, event: "PreToolUse", cause: cause)
                    ?? SessionStatusObservation(.working, cause: cause("hook: PreToolUse \(Self.toolLabel(tool))"))
            case "PermissionRequest":
                let tool = object["tool_name"] as? String
                return Self.claudeInteractiveObservation(toolName: tool, event: "PermissionRequest", cause: cause)
                    ?? SessionStatusObservation(
                        .waitingForInput,
                        waitingReason: .permission,
                        cause: cause("hook: PermissionRequest \(Self.toolLabel(tool))")
                    )
            case "Stop": return SessionStatusObservation(.readyForReview, cause: cause("hook: Stop"))
            case "PostToolUse":
                return SessionStatusObservation(
                    .working,
                    cause: cause("hook: PostToolUse \(Self.toolLabel(object["tool_name"] as? String))")
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
                        cause: cause("hook: PreToolUse ask_question")
                      )
                    : SessionStatusObservation(.working, cause: cause("hook: PreToolUse \(Self.toolLabel(toolName))"))
            case "PostToolUse":
                if Self.antigravityRequestsPlanFeedback(payload) {
                    return SessionStatusObservation(
                        .waitingForInput,
                        waitingReason: .planApproval,
                        cause: cause("hook: PostToolUse write_to_file with RequestFeedback")
                    )
                }
                return SessionStatusObservation(
                    .working,
                    cause: cause("hook: PostToolUse \(Self.toolLabel((payload["toolCall"] as? [String: Any])?["name"] as? String))")
                )
            case "PreInvocation":
                // Before every model call, the first of a turn included —
                // the turn-start signal for a reply with no tool call.
                return SessionStatusObservation(
                    .working,
                    cause: cause("hook: PreInvocation \((payload["invocationNum"] as? Int).map(String.init) ?? "?")")
                )
            case "Stop":
                // `fullyIdle: false` means async work (a background command)
                // is still running; the turn is not over yet.
                guard (payload["fullyIdle"] as? Bool) == true else { return nil }
                let reason = (payload["terminationReason"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
                return SessionStatusObservation(.readyForReview, cause: cause("hook: Stop fullyIdle=true \(reason)"))
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
            case "UserPromptSubmit":
                return SessionStatusObservation(.working, cause: cause("hook: UserPromptSubmit"))
            case "Interrupt":
                return SessionStatusObservation(.readyForReview, cause: cause("hook: Interrupt"))
            case "PreToolUse":
                let toolName = (object["tool_name"] as? String)?.lowercased()
                if toolName == "request_user_input" || toolName == "askuserquestion" {
                    return SessionStatusObservation(
                        .waitingForInput,
                        waitingReason: .question,
                        cause: cause("hook: PreToolUse \(Self.toolLabel(toolName))")
                    )
                }
                return SessionStatusObservation(.working, cause: cause("hook: PreToolUse \(Self.toolLabel(toolName))"))
            case "PostToolUse":
                return SessionStatusObservation(
                    .working,
                    cause: cause("hook: PostToolUse \(Self.toolLabel(object["tool_name"] as? String))")
                )
            case "Stop":
                // Codex renders a finalized Plan-mode response specially and
                // reports `last_assistant_message: null` on the Stop hook.
                if object["last_assistant_message"] is NSNull {
                    return SessionStatusObservation(
                        .waitingForInput,
                        waitingReason: .planApproval,
                        cause: cause("hook: Stop with last_assistant_message=null (plan mode)")
                    )
                }
                return SessionStatusObservation(.readyForReview, cause: cause("hook: Stop"))
            case "PermissionRequest":
                return SessionStatusObservation(
                    .waitingForInput,
                    waitingReason: .permission,
                    cause: cause("hook: PermissionRequest")
                )
            default: return nil
            }
        case .openCode:
            // Written by the generated user-level plugin
            // (`HookConfigurationWriter.openCodePluginContents`) as a flat
            // `{"event": "<type>", …fields}` line. `session.idle` is a naming
            // trap: it means "turn ended, composer free" (`.readyForReview`).
            guard let eventName = object["event"] as? String else { return nil }
            switch eventName {
            case "tool.execute.before", "tool.execute.after":
                return SessionStatusObservation(
                    .working,
                    cause: cause("hook: \(eventName) \(Self.toolLabel(object["tool"] as? String))")
                )
            case "session.status":
                switch object["status"] as? String {
                case "busy":
                    return SessionStatusObservation(.working, cause: cause("hook: session.status busy"))
                case "retry":
                    let attempt = (object["attempt"] as? Int).map { " attempt=\($0)" } ?? ""
                    return SessionStatusObservation(.working, cause: cause("hook: session.status retry\(attempt)"))
                case "idle":
                    return SessionStatusObservation(.readyForReview, cause: cause("hook: session.status idle"))
                default:
                    return nil
                }
            case "session.idle":
                return SessionStatusObservation(.readyForReview, cause: cause("hook: session.idle"))
            case "permission.asked", "permission.v2.asked":
                return SessionStatusObservation(
                    .waitingForInput,
                    waitingReason: .permission,
                    cause: cause("hook: \(eventName)")
                )
            case "question.asked", "question.v2.asked":
                return SessionStatusObservation(
                    .waitingForInput,
                    waitingReason: .question,
                    cause: cause("hook: \(eventName)")
                )
            case "permission.replied", "permission.v2.replied",
                 "question.replied", "question.v2.replied",
                 "question.rejected", "question.v2.rejected":
                // The dialog closed and the turn carries on.
                return SessionStatusObservation(.working, cause: cause("hook: \(eventName)"))
            case "session.error":
                return SessionStatusObservation(.readyForReview, cause: cause("hook: session.error"))
            case "session.compacted":
                return SessionStatusObservation(.working, cause: cause("hook: session.compacted"))
            default:
                // `session.created` carries identity, not activity.
                return nil
            }
        case .cursorAgent:
            guard let eventName = object["hook_event_name"] as? String else { return nil }
            let payload = object["payload"] as? [String: Any] ?? object
            switch eventName {
            case "beforeSubmitPrompt":
                // Turn accepted — Cursor is busy before any tool hook fires.
                return SessionStatusObservation(.working, cause: cause("hook: \(eventName)"))
            case "preToolUse", "beforeShellExecution", "beforeMCPExecution":
                let tool = (payload["tool_name"] as? String) ?? (payload["toolName"] as? String)
                let lowered = tool?.lowercased()
                if lowered == "askquestion" || lowered == "ask_question" || lowered == "request_user_input" {
                    return SessionStatusObservation(
                        .waitingForInput,
                        waitingReason: .question,
                        cause: cause("hook: \(eventName) \(Self.toolLabel(tool))")
                    )
                }
                // An approval dialog that may follow is read off the screen
                // (`CursorDialog`); no hook reports it.
                return SessionStatusObservation(.working, cause: cause("hook: \(eventName) \(Self.toolLabel(tool))"))
            case "postToolUse", "afterShellExecution", "afterFileEdit", "subagentStart", "preCompact":
                // `afterShellExecution` also closes an approval dialog — a
                // skipped command arrives as an ordinary, empty run.
                return SessionStatusObservation(.working, cause: cause("hook: \(eventName)"))
            case "afterAgentThought":
                // A turn submitted as a `stop` hook's `followup_message`
                // fires no `beforeSubmitPrompt`; its thinking is the first sign.
                return SessionStatusObservation(.working, cause: cause("hook: afterAgentThought"))
            case "postToolUseFailure":
                if (payload["is_interrupt"] as? Bool) == true {
                    return SessionStatusObservation(.readyForReview, cause: cause("hook: postToolUseFailure interrupted"))
                }
                return SessionStatusObservation(.working, cause: cause("hook: postToolUseFailure"))
            case "afterAgentResponse", "sessionEnd", "stop":
                // Interactive CLI fires `afterAgentResponse` then `stop` when
                // the turn ends and the follow-up composer returns. `sessionEnd`
                // is session teardown (also ready — the pane is done).
                return SessionStatusObservation(.readyForReview, cause: cause("hook: \(eventName)"))
            default:
                return nil
            }
        }
    }

    private static func claudeInteractiveObservation(
        toolName: String?,
        event: String,
        cause: (String) -> String
    ) -> SessionStatusObservation? {
        switch toolName?.lowercased() {
        case "exitplanmode":
            return SessionStatusObservation(
                .waitingForInput,
                waitingReason: .planApproval,
                cause: cause("hook: \(event) ExitPlanMode")
            )
        case "askuserquestion":
            return SessionStatusObservation(
                .waitingForInput,
                waitingReason: .question,
                cause: cause("hook: \(event) AskUserQuestion")
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

    // MARK: - Payload summary extraction

    /// A compact, bounded representation of the most diagnostic fields from
    /// the raw hook JSON — the content that explains *why* the event fired,
    /// not just its type. Appended to the `cause` so a single log line
    /// carries enough to diagnose without tailing the raw JSONL file.
    ///
    /// Each provider sends a different payload shape, so extraction is
    /// per-agent. The result is capped at `maxLength` characters to keep
    /// log lines readable; long strings are truncated with `…`.
    static func payloadSummary(
        from object: [String: Any],
        agent: AgentKind,
        maxLength: Int = 200
    ) -> String? {
        let raw: String?
        switch agent {
        case .claudeCode:
            raw = claudePayloadSummary(from: object)
        case .antigravity:
            raw = antigravityPayloadSummary(from: object)
        case .codexCLI:
            raw = codexPayloadSummary(from: object)
        case .openCode:
            raw = openCodePayloadSummary(from: object)
        case .cursorAgent:
            raw = cursorPayloadSummary(from: object)
        }
        guard let raw, !raw.isEmpty else { return nil }
        return raw.count <= maxLength ? raw : String(raw.prefix(maxLength)) + "…"
    }

    // MARK: Claude Code

    /// Extracts the diagnostic fields from Claude Code's hook JSON.
    ///
    /// Claude sends a flat top-level object:
    /// ```json
    /// {
    ///   "hook_event_name": "PreToolUse",
    ///   "tool_name": "AskUserQuestion",
    ///   "tool_input": { "question": "Which approach…", … },
    ///   "session_id": "…",
    ///   "cwd": "…"
    /// }
    /// ```
    ///
    /// For `Notification` events: `notification_type` + `message`.
    /// For tool events: `tool_input` (the actual arguments).
    private static func claudePayloadSummary(from object: [String: Any]) -> String? {
        // Notification events carry `message` at the top level.
        if let notificationType = object["notification_type"] as? String {
            let message = object["message"] as? String
            return message.map { "\(notificationType): \($0)" } ?? notificationType
        }

        // StopFailure: `error` is the type, `error_details` the message.
        if let details = object["error_details"] as? String {
            let type = object["error"] as? String
            return type.map { "\($0): \(details)" } ?? details
        }

        // Tool events: extract from tool_input.
        guard let toolInput = object["tool_input"] as? [String: Any],
              !toolInput.isEmpty else { return nil }
        return compactJSON(toolInput)
    }

    // MARK: Antigravity

    /// Extracts the diagnostic fields from Antigravity's hook JSON.
    ///
    /// Antigravity sends:
    /// ```json
    /// {"event":"PreToolUse","payload":{"toolCall":{"name":"ask_question","args":{…}}}}
    /// ```
    private static func antigravityPayloadSummary(from object: [String: Any]) -> String? {
        guard let payload = object["payload"] as? [String: Any] else { return nil }

        // Stop events: report fullyIdle and, when set, the error.
        if let fullyIdle = payload["fullyIdle"] as? Bool {
            let error = (payload["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return "fullyIdle=\(fullyIdle)" + (error.map { ", error=\($0)" } ?? "")
        }

        // Tool events: extract args from toolCall.
        guard let toolCall = payload["toolCall"] as? [String: Any] else { return nil }
        let toolName = toolCall["name"] as? String
        if let args = toolCall["args"] as? [String: Any], !args.isEmpty {
            let argsText = compactJSON(args)
            return toolName.map { "\($0)(\(argsText))" } ?? argsText
        }
        return toolName
    }

    // MARK: Codex CLI

    /// Extracts the diagnostic fields from Codex CLI's hook JSON.
    ///
    /// Codex sends a flat top-level object with `hook_event_name`,
    /// `tool_name`, and `tool_input`.
    private static func codexPayloadSummary(from object: [String: Any]) -> String? {
        if let toolInput = object["tool_input"] as? [String: Any], !toolInput.isEmpty {
            return compactJSON(toolInput)
        }
        // Stop events may carry last_assistant_message.
        if let message = object["last_assistant_message"] as? String, !message.isEmpty {
            return "last_message: \(message)"
        }
        return nil
    }

    // MARK: OpenCode

    /// The plugin forwards a few flat fields per event; older lines carry
    /// none.
    private static func openCodePayloadSummary(from object: [String: Any]) -> String? {
        if let message = object["message"] as? String { return "error: \(message)" }
        if let permission = object["permission"] as? String {
            let patterns = (object["patterns"] as? [String])?.joined(separator: ", ")
            return patterns.map { "\(permission): \($0)" } ?? permission
        }
        if let tool = object["tool"] as? String { return "tool=\(tool)" }
        return nil
    }

    // MARK: Cursor Agent

    private static func cursorPayloadSummary(from object: [String: Any]) -> String? {
        let payload = object["payload"] as? [String: Any] ?? object["request"] as? [String: Any] ?? object
        if let toolInput = payload["tool_input"] as? [String: Any], !toolInput.isEmpty {
            return compactJSON(toolInput)
        }
        if let command = payload["command"] as? String, !command.isEmpty {
            return "command=\(command)"
        }
        if let tool = payload["tool_name"] as? String {
            return "tool=\(tool)"
        }
        if let status = payload["status"] as? String, !status.isEmpty {
            return "status=\(status)"
        }
        if let text = payload["text"] as? String, !text.isEmpty {
            return "text=\(text)"
        }
        return nil
    }

    // MARK: Formatting

    /// Formats a dictionary as a compact, single-line string for log output.
    /// Prefers a readable `key=value, …` form over raw JSON.
    private static func compactJSON(_ dict: [String: Any]) -> String {
        dict.sorted(by: { $0.key < $1.key })
            .map { key, value in
                let v: String
                switch value {
                case let s as String: v = s
                case let n as NSNumber where CFBooleanGetTypeID() == CFGetTypeID(n):
                    v = n.boolValue ? "true" : "false"
                case let n as NSNumber: v = n.stringValue
                case is NSNull: v = "null"
                case let arr as [Any]: v = "[\(arr.count) items]"
                case let d as [String: Any]: v = "{\(d.count) keys}"
                default: v = String(describing: value)
                }
                return "\(key)=\(v)"
            }
            .joined(separator: ", ")
    }

    private static func antigravityRequestsPlanFeedback(_ payload: [String: Any]) -> Bool {
        guard let toolCall = payload["toolCall"] as? [String: Any],
              toolCall["name"] as? String == "write_to_file" else { return false }
        let arguments = (toolCall["args"] as? [String: Any]) ?? (payload["args"] as? [String: Any])
        let metadata = arguments?["ArtifactMetadata"] as? [String: Any]
        return metadata?["RequestFeedback"] as? Bool == true
    }

    // MARK: - Permission requests

    /// Claude and Codex only, matching `permissionRequestEvent`'s own
    /// restriction below — OpenCode's `permission.asked` line carries no
    /// tool name or arguments, and Antigravity has no permission hook.
    static func permissionRequestEvent(forLine line: String, agent: AgentKind) -> HookPermissionRequestEvent? {
        guard agent == .claudeCode || agent == .codexCLI else { return nil }
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["hook_event_name"] as? String == "PermissionRequest",
              let toolName = object["tool_name"] as? String else { return nil }
        let input = object["tool_input"] as? [String: Any] ?? [:]
        return HookPermissionRequestEvent(
            agent: agent,
            toolName: toolName,
            primaryArgument: primaryArgument(toolName: toolName, input: input),
            timestamp: .now
        )
    }

    /// Claude's `SessionStart` names the conversation the process is in now.
    /// After `/clear` or a fork that is a new id, and resuming the old one
    /// would bring back the conversation the user just left.
    ///
    /// OpenCode's `session.created` (root sessions only — the plugin drops
    /// sub-agents) is the id of the conversation the TUI just started, the
    /// first prompt's or a `/new`'s; it replaces discovering it afterwards.
    static func sessionIdentityEvent(forLine line: String, agent: AgentKind) -> HookSessionIdentityEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch agent {
        case .claudeCode:
            guard object["hook_event_name"] as? String == "SessionStart",
                  let nativeSessionID = object["session_id"] as? String,
                  !nativeSessionID.isEmpty else { return nil }
            return HookSessionIdentityEvent(agent: agent, nativeSessionID: nativeSessionID, source: object["source"] as? String)
        case .openCode:
            guard object["event"] as? String == "session.created",
                  let nativeSessionID = object["sessionID"] as? String,
                  !nativeSessionID.isEmpty else { return nil }
            return HookSessionIdentityEvent(agent: agent, nativeSessionID: nativeSessionID, source: "created")
        case .codexCLI, .antigravity, .cursorAgent:
            return nil
        }
    }

    /// The one argument `PermissionPattern.normalize` needs to build a
    /// human-readable pattern: a shell command, a file path, or a URL,
    /// whichever this tool's input carries.
    private static func primaryArgument(toolName: String, input: [String: Any]) -> String? {
        switch toolName.lowercased() {
        case "bash", "shell", "exec", "local_shell":
            input["command"] as? String
        case "edit", "write", "multiedit", "notebookedit":
            (input["file_path"] as? String) ?? (input["path"] as? String)
        case "webfetch":
            input["url"] as? String
        default:
            nil
        }
    }
}

/// Which conversation a provider process reports it is in, from a hook event.
public struct HookSessionIdentityEvent: Sendable, Equatable {
    public let agent: AgentKind
    /// The provider's id for the conversation (Claude's `session_id`).
    public let nativeSessionID: String
    /// Why the provider (re)started the conversation: `startup`, `resume`,
    /// `clear`, `compact`, or `fork` for Claude.
    public let source: String?

    public init(agent: AgentKind, nativeSessionID: String, source: String?) {
        self.agent = agent
        self.nativeSessionID = nativeSessionID
        self.source = source
    }
}

/// One permission ask, distilled from a hook event to what
/// `PermissionPattern.normalize` (in the app layer) needs to group it — no
/// `Any` in the public type, so the stream stays `Sendable`.
public struct HookPermissionRequestEvent: Sendable, Equatable {
    public let agent: AgentKind
    public let toolName: String
    public let primaryArgument: String?
    public let timestamp: Date

    public init(agent: AgentKind, toolName: String, primaryArgument: String?, timestamp: Date) {
        self.agent = agent
        self.toolName = toolName
        self.primaryArgument = primaryArgument
        self.timestamp = timestamp
    }
}
