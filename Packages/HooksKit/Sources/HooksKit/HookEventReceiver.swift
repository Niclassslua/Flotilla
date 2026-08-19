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
    private let pollInterval: Duration
    private let continuation: AsyncStream<SessionStatus>.Continuation
    public let statusStream: AsyncStream<SessionStatus>
    private var task: Task<Void, Never>?

    public init(filePath: URL, pollInterval: Duration = .milliseconds(400)) {
        self.filePath = filePath
        self.pollInterval = pollInterval
        var continuation: AsyncStream<SessionStatus>.Continuation!
        self.statusStream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func start() {
        guard task == nil else { return }
        let filePath = self.filePath
        let pollInterval = self.pollInterval
        let continuation = self.continuation

        task = Task {
            var readOffset: UInt64 = 0
            var pendingLine = ""
            while !Task.isCancelled {
                if let handle = try? FileHandle(forReadingFrom: filePath) {
                    defer { try? handle.close() }
                    if (try? handle.seekToEnd()) ?? 0 >= readOffset {
                        try? handle.seek(toOffset: readOffset)
                        if let data = try? handle.readToEnd(), !data.isEmpty {
                            readOffset += UInt64(data.count)
                            pendingLine += String(decoding: data, as: UTF8.self)
                            let lines = pendingLine.components(separatedBy: "\n")
                            // The last element is either "" (the file ended
                            // exactly on a newline) or a partial line still
                            // being written — hold it back either way.
                            pendingLine = lines.last ?? ""
                            for line in lines.dropLast() where !line.isEmpty {
                                if let status = Self.status(forLine: line) {
                                    continuation.yield(status)
                                }
                            }
                        }
                    } else {
                        // The file shrank (session restarted, event file
                        // truncated for a fresh launch) — start over.
                        readOffset = 0
                        pendingLine = ""
                    }
                }
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    static func status(forLine line: String) -> SessionStatus? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventName = object["hook_event_name"] as? String else { return nil }
        switch eventName {
        case "Notification": return .waitingForInput
        case "Stop": return .ready
        case "PostToolUse": return .working
        default: return nil
        }
    }
}
