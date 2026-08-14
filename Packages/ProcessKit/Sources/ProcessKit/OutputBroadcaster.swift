import Foundation

/// `AsyncStream` is single-consumer: two independent `for await` loops
/// racing over the same stream instance don't each see every element —
/// whichever loop happens to be awaiting `next()` gets it, starving the
/// other. Both `TerminalController` and HooksKit's `SessionStatusObserver`
/// need every byte of a session's output independently, so
/// `PTYProcessProtocol.outputStream` is backed by this broadcaster: each
/// access to the property creates a fresh subscription.
///
/// New subscribers replay the full buffered history before receiving live
/// broadcasts (capped at `historyLimit` chunks) — this isn't just a nicety,
/// it's required for correctness: a subscriber created even slightly after
/// `broadcast(_:)` is first called would otherwise silently miss that
/// output forever (this is exactly how a naive lazy-subscribe design lost
/// data in practice: a test called `simulateOutput` before its `async let`
/// consumer task had actually started running and subscribed).
final class OutputBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Data>.Continuation] = [:]
    private var history: [Data] = []
    private var historyStart = 0
    private var isFinished = false
    private let historyLimit = 4096

    func subscribe() -> AsyncStream<Data> {
        AsyncStream { continuation in
            lock.lock()
            if isFinished {
                let replay = Array(history[historyStart...])
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
            for chunk in history[historyStart...] { continuation.yield(chunk) }
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: subscriberID)
                self.lock.unlock()
            }
        }
    }

    func broadcast(_ data: Data) {
        lock.lock()
        history.append(data)
        if history.count - historyStart > historyLimit {
            historyStart += 1
        }
        if historyStart >= historyLimit {
            history.removeFirst(historyStart)
            historyStart = 0
        }
        let subscribers = Array(continuations.values)
        lock.unlock()
        for continuation in subscribers {
            continuation.yield(data)
        }
    }

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
