import Foundation
import os

/// Opt-in main-thread tracing, added to diagnose the multi-second hang when
/// the workspace switches from Grid to Board (Kanban) layout.
///
/// Every call site is inert unless the process was launched with
/// `FLOTILLA_PERF=1` or `defaults write com.niclassslua.flotilla FlotillaPerf -bool YES`,
/// so a normal run pays one `Bool` check per probe. Output goes to the unified
/// log (never `print`), so it can be read live while the UI is frozen:
///
///     log stream --level debug --style compact --predicate 'subsystem == "com.niclassslua.flotilla"'
///
/// `--level debug` matters: the per-body probes are logged at `debug`/`info`,
/// which the unified log keeps in memory only. Warnings (slow blocks) and
/// errors (main-thread stalls) survive without it:
///
///     log show --last 5m --style compact --predicate 'subsystem == "com.niclassslua.flotilla"'
///
/// Intervals are also emitted as signposts, so the same run can be recorded in
/// Instruments' "os_signpost" / "SwiftUI" templates without changing the code.
enum PerfLog {
    static let subsystem = "com.niclassslua.flotilla"
    static let logger = Logger(subsystem: subsystem, category: "Perf")
    static let signposter = OSSignposter(subsystem: subsystem, category: "Perf")

    /// Anything shorter than this is noise when hunting a multi-second freeze;
    /// it is still emitted at `debug` level, just not as a warning.
    static let slowThresholdMilliseconds = 2.0

    static let isEnabled: Bool = {
        ProcessInfo.processInfo.environment["FLOTILLA_PERF"] == "1"
            || UserDefaults.standard.bool(forKey: "FlotillaPerf")
    }()

    private static let state = OSAllocatedUnfairLock(initialState: TraceState())

    private struct TraceState {
        var transition: String = "startup"
        var transitionStart: DispatchTime = .now()
        var phase: String = "idle"
        var counts: [String: Int] = [:]
    }

    /// Marks the start of a user-visible transition. Every later `event` and
    /// `measure` line carries the elapsed time since this point, which turns a
    /// pile of timestamps into a readable "what happened after the click"
    /// timeline.
    static func beginTransition(_ name: String) {
        guard isEnabled else { return }
        state.withLock {
            $0.transition = name
            $0.transitionStart = .now()
            $0.counts.removeAll()
        }
        logger.notice("── transition begin: \(name, privacy: .public)")
        signposter.emitEvent("transition", "\(name, privacy: .public)")
    }

    /// Milliseconds since the current transition began.
    static func sinceTransition() -> Double {
        let start = state.withLock { $0.transitionStart }
        return Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }

    static func event(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        // Materialized up front: `Logger`'s interpolation takes an escaping
        // autoclosure, which a non-escaping parameter cannot be captured by.
        let text = message()
        logger.info("+\(sinceTransition(), format: .fixed(precision: 1))ms \(text, privacy: .public)")
    }

    /// Counts how often a probe is hit within the current transition and logs
    /// the running total — the cheap way to spot a re-render storm (a SwiftUI
    /// body that evaluates hundreds of times per switch).
    static func bump(_ name: String, _ detail: @autoclosure () -> String = "") {
        guard isEnabled else { return }
        let context = detail()
        let count = state.withLock { state -> Int in
            let next = (state.counts[name] ?? 0) + 1
            state.counts[name] = next
            return next
        }
        logger.debug("+\(sinceTransition(), format: .fixed(precision: 1))ms \(name, privacy: .public) #\(count) \(context, privacy: .public)")
    }

    /// Wraps a synchronous main-thread block in a signpost interval, logging a
    /// warning when it exceeds `slowThresholdMilliseconds`. The name is also
    /// published as the current phase so the stall monitor can attribute a
    /// beachball to whatever was running when it started.
    @discardableResult
    static func measure<T>(
        _ name: StaticString,
        _ detail: @autoclosure () -> String = "",
        body: () throws -> T
    ) rethrows -> T {
        guard isEnabled else { return try body() }
        let label = String(describing: name)
        let context = detail()
        let previousPhase = state.withLock { state -> String in
            let previous = state.phase
            state.phase = label
            return previous
        }
        let signpostState = signposter.beginInterval(name)
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
            signposter.endInterval(name, signpostState)
            state.withLock { $0.phase = previousPhase }
            if milliseconds >= slowThresholdMilliseconds {
                logger.warning("+\(sinceTransition(), format: .fixed(precision: 1))ms SLOW \(label, privacy: .public) \(milliseconds, format: .fixed(precision: 1))ms \(context, privacy: .public)")
            } else {
                logger.debug("+\(sinceTransition(), format: .fixed(precision: 1))ms \(label, privacy: .public) \(milliseconds, format: .fixed(precision: 2))ms \(context, privacy: .public)")
            }
        }
        return try body()
    }

    /// Whatever `measure` block is currently on the stack, or `idle`.
    static var currentPhase: String {
        state.withLock { $0.phase }
    }
}

/// Detects "the app is beachballing" without a debugger attached: a background
/// timer pings the main queue and reports whenever a ping is not answered
/// within `threshold`. Round-trip latency on an idle main thread is
/// sub-millisecond, so any report here is a real hang, and the phase name tells
/// us which instrumented block it started in.
final class MainThreadStallMonitor: @unchecked Sendable {
    static let shared = MainThreadStallMonitor()

    private let queue = DispatchQueue(label: "com.niclassslua.flotilla.perf.stall", qos: .utility)
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private var timer: DispatchSourceTimer?

    private struct State {
        var pingSentAt: DispatchTime?
        var reportedPhase: String?
    }

    private struct Configuration {
        static let pollInterval: DispatchTimeInterval = .milliseconds(100)
        static let threshold = 0.25
    }

    func start() {
        guard PerfLog.isEnabled, timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Configuration.pollInterval, repeating: Configuration.pollInterval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
        PerfLog.logger.notice("main-thread stall monitor armed (threshold \(Configuration.threshold * 1000, format: .fixed(precision: 0))ms)")
    }

    private func poll() {
        let outstanding: DispatchTime? = lock.withLock { $0.pingSentAt }

        if let outstanding {
            let blocked = Double(DispatchTime.now().uptimeNanoseconds &- outstanding.uptimeNanoseconds) / 1_000_000_000
            guard blocked >= Configuration.threshold else { return }
            let phase = PerfLog.currentPhase
            let alreadyReported = lock.withLock { state -> Bool in
                let seen = state.reportedPhase != nil
                state.reportedPhase = phase
                return seen
            }
            if !alreadyReported {
                PerfLog.logger.error("⚠️ main thread stalled ≥\(blocked * 1000, format: .fixed(precision: 0))ms — phase: \(phase, privacy: .public)")
            }
            return
        }

        let sentAt = DispatchTime.now()
        lock.withLock { $0.pingSentAt = sentAt }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let waited = Double(DispatchTime.now().uptimeNanoseconds &- sentAt.uptimeNanoseconds) / 1_000_000
            let reportedPhase: String? = self.lock.withLock { state in
                let phase = state.reportedPhase
                state.pingSentAt = nil
                state.reportedPhase = nil
                return phase
            }
            if let reportedPhase {
                PerfLog.logger.error("✅ main thread recovered after \(waited, format: .fixed(precision: 0))ms — phase was: \(reportedPhase, privacy: .public)")
            }
        }
    }
}
