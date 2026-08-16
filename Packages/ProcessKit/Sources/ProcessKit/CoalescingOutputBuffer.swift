import Foundation

/// Collapses a burst of PTY reads arriving on a background stream into a
/// single flush per consumer turn, instead of one main-actor hop per chunk.
///
/// A chatty TUI repaint arrives as many small reads from the PTY master, each
/// wrapped in its own `Data` by `OutputBroadcaster`. Feeding the terminal
/// emulator once per chunk means the emulator (and any UI observing it) sees
/// a screen mid-repaint — including moments where the TUI's cursor-hide
/// escape sequence has been applied but its matching cursor-show has not yet
/// arrived. Buffering here and draining once per scheduled flush guarantees
/// escape sequence pairs like that resolve within a single flush.
public final class CoalescingOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    public init() {}

    /// Appends `data` to the pending buffer. Returns `true` only when this
    /// append is the first since the last `drain()` — the caller should
    /// schedule exactly one flush in that case. Every subsequent append
    /// before the flush runs returns `false`, so callers never schedule more
    /// than one flush per drain cycle.
    @discardableResult
    public func append(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let shouldSchedule = pending.isEmpty
        pending.append(data)
        return shouldSchedule
    }

    /// Returns everything appended since the last `drain()`, in arrival
    /// order, and clears the buffer so the next `append` schedules again.
    public func drain() -> Data {
        lock.lock()
        defer { lock.unlock() }
        let result = pending
        pending = Data()
        return result
    }
}
