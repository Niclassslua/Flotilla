import Foundation
import SessionKit

/// Tails the JSONL file `HookConfigurationWriter` points a launched agent's
/// hooks at, and emits the status each event implies.
///
/// Same `AsyncStream<SessionStatus>` shape as `SessionScreenMonitor`, so
/// `HookCoordinator` can run this alongside the screen monitor with no
/// change to how either stream is consumed — see `HookCoordinator.observe`.
/// Strictly observational, matching HooksKit's module-wide constraint: this
/// type only ever produces a status, it never writes to or terminates the
/// session it's watching.
public final class HookEventReceiver: @unchecked Sendable {
    private let filePath: URL
    private let agent: AgentKind
    private let pollInterval: Duration
    private let continuation: AsyncStream<SessionStatus>.Continuation
    public let statusStream: AsyncStream<SessionStatus>
    private let taskLock = NSLock()
    private var task: Task<Void, Never>?

    public init(filePath: URL, agent: AgentKind, pollInterval: Duration = .milliseconds(400)) {
        self.filePath = filePath
        self.agent = agent
        self.pollInterval = pollInterval
        var continuation: AsyncStream<SessionStatus>.Continuation!
        self.statusStream = AsyncStream { continuation = $0 }
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
                                if let status = Self.status(forLine: line, agent: agent) {
                                    continuation.yield(status)
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

    static func status(forLine line: String, agent: AgentKind) -> SessionStatus? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        switch agent {
        case .claudeCode:
            guard let eventName = object["hook_event_name"] as? String else { return nil }
            switch eventName {
            case "Notification": return .waitingForInput
            case "Stop": return .ready
            case "PostToolUse": return .working
            default: return nil
            }
        case .antigravity:
            guard let eventName = object["event"] as? String,
                  let payload = object["payload"] as? [String: Any] else { return nil }
            switch eventName {
            case "PreToolUse":
                let toolName = (payload["toolCall"] as? [String: Any])?["name"] as? String
                return toolName == "ask_question" ? .waitingForInput : .working
            case "PostToolUse":
                return .working
            case "Stop":
                return (payload["fullyIdle"] as? Bool) == true ? .ready : nil
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
            case "PostToolUse": return .working
            case "Stop": return .ready
            case "PermissionRequest": return .waitingForInput
            default: return nil
            }
        case .openCode:
            // Written by the generated stable project plugin (see
            // HookConfigurationWriter.openCodePluginContents) as a flat
            // {"event": "<name>"} line — no nested payload needed for any
            // of these mappings. session.idle is a naming trap: it means
            // "turn ended, composer free" (Flotilla's .ready), not .idle.
            guard let eventName = object["event"] as? String else { return nil }
            switch eventName {
            case "tool.execute.after": return .working
            case "session.idle": return .ready
            case "permission.asked", "question.asked": return .waitingForInput
            default: return nil
            }
        }
    }
}
