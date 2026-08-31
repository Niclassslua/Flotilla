import Foundation

/// `AsyncStream` is single-consumer: two independent `for await` loops
/// racing over the same stream instance don't each see every element —
/// whichever loop happens to be awaiting `next()` gets it, starving the
/// other. Independent consumers each need every byte of a session's output,
/// so `PTYProcessProtocol.outputStream` is backed by this broadcaster: each
/// access to the property creates a fresh subscription.
///
/// New subscribers replay the full buffered history before receiving live
/// broadcasts (capped at `maxHistoryBytes`) — this isn't just a nicety,
/// it's required for correctness: a subscriber created even slightly after
/// `broadcast(_:)` is first called would otherwise silently miss that
/// output forever (this is exactly how a naive lazy-subscribe design lost
/// data in practice: a test called `simulateOutput` before its `async let`
/// consumer task had actually started running and subscribed).
final class OutputBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Data>.Continuation] = [:]
    private var history: [Data] = []
    private var historyByteSize = 0
    private var isFinished = false
    private let maxHistoryBytes = 256 * 1_024

    func subscribe() -> AsyncStream<Data> {
        AsyncStream { [weak self] continuation in
            guard let self else { return }
            lock.lock()
            if isFinished {
                let replay = Array(self.history[0..<min(self.history.count, 1024)])
                lock.unlock()
                for chunk in replay { continuation.yield(chunk) }
                continuation.finish()
                return
            }

            // Register and replay while still holding the lock, so a
            // concurrent broadcast() can't interleave with (and possibly
            // duplicate or precede) the history replay for this subscriber.
            let subscriberID = UUID()
            continuations[subscriberID] = continuation
            for i in 0..<history.count {
                continuation.yield(history[i])
            }
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: subscriberID)
                self.lock.unlock()
            }
        }
    }

    func start() {
        lock.lock()
        isFinished = false  // Reset so new subscribers don't immediately finish
        history.removeAll()
        historyByteSize = 0
        continuations.removeAll()
        lock.unlock()
    }

    func broadcast(_ data: Data) {
        lock.lock()
        history.append(data)
        historyByteSize += data.count
        if historyByteSize > maxHistoryBytes {
            trimHistoryLocked()
        }
        let subscribers = Array(continuations.values)
        lock.unlock()
        for continuation in subscribers {
            continuation.yield(data)
        }
    }

    /// Drops the oldest chunks in one pass rather than one `removeFirst()` at
    /// a time.
    ///
    /// `Array.removeFirst()` is O(n): it shifts every remaining element down.
    /// A TUI produces small chunks, so at 256 KB of history this array holds
    /// thousands of them and the old loop paid a multi-kilobyte memmove on
    /// *every* PTY read, for a history that in this app has no reader — the
    /// sole subscriber (`TerminalController.consumeOutput`) subscribes inside
    /// `init`, before the process can emit anything. Slicing once, with slack,
    /// makes the amortized cost constant.
    private func trimHistoryLocked() {
        var dropped = 0
        var index = 0
        let target = historyByteSize - maxHistoryBytes + Self.trimSlackBytes
        while index < history.count, dropped < target {
            dropped += history[index].count
            index += 1
        }
        guard index > 0 else { return }
        history.removeFirst(index)
        historyByteSize = max(0, historyByteSize - dropped)
    }

    /// Trim past the cap so trimming happens once per slack's worth of output
    /// instead of on every chunk.
    private static let trimSlackBytes = 64 * 1_024

    func finish() {
        lock.lock()
        isFinished = true
        let subscribers = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in subscribers {
            continuation.finish()
        }
    }
}
