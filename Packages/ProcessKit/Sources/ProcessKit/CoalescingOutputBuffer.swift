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
    private let capacity: Int
    private var droppedBytes = 0

    /// Ceiling on how much unflushed output is held.
    ///
    /// Without one this buffer is an amplifier for main-thread stalls: the PTY
    /// reader runs on a background queue and the drain runs on the main actor,
    /// so anything that blocks the main actor lets `pending` grow without
    /// bound, and the flush that eventually runs then feeds one enormous byte
    /// array to the emulator — blocking the main actor for longer still.
    ///
    /// Dropping the oldest bytes is the right trade. The emulator can only
    /// display a screenful, everything here is on its way to being overdrawn
    /// within milliseconds, and durable history is `TerminalController`'s
    /// replay buffer and the persisted scrollback, neither of which goes
    /// through this path.
    public static let defaultCapacity = 4 * 1_024 * 1_024

    public init(capacity: Int = CoalescingOutputBuffer.defaultCapacity) {
        self.capacity = max(capacity, 64 * 1_024)
    }

    /// Total bytes discarded because the buffer was over capacity when they
    /// arrived. Non-zero means the main actor could not keep up.
    public var totalDroppedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedBytes
    }

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
        if pending.count > capacity {
            // Keep the newest `capacity` bytes: they are the ones that decide
            // what ends up on screen. Trimming to a whole capacity's worth
            // rather than back to a high-water mark keeps this amortized —
            // a sustained overflow costs one copy per capacity of output.
            let overflow = pending.count - capacity
            droppedBytes += overflow
            pending = Data(pending.suffix(capacity))
        }
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
