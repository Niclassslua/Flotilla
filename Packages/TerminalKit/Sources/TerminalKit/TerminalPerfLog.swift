import Foundation
import os

/// The TerminalKit-local half of the app's `PerfLog`. It is duplicated rather
/// than shared because TerminalKit deliberately has no dependency on the app
/// target; both write to the same `subsystem` so one `log stream` shows the
/// app-side and terminal-side probes interleaved on one timeline.
///
/// Inert unless the process is launched with `FLOTILLA_PERF=1`.
enum TerminalPerfLog {
    static let logger = Logger(subsystem: "com.niclassslua.flotilla", category: "TerminalPerf")
    static let signposter = OSSignposter(subsystem: "com.niclassslua.flotilla", category: "TerminalPerf")

    static let isEnabled: Bool = {
        if ProcessInfo.processInfo.environment["FLOTILLA_PERF"] == "1" {
            return true
        }
        guard Bundle.main.bundleIdentifier != "com.niclassslua.flotilla.ephemeral" else {
            return false
        }
        return UserDefaults.standard.bool(forKey: "FlotillaPerf")
    }()

    static func event(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        logger.info("\(text, privacy: .public)")
    }

    @discardableResult
    static func measure<T>(
        _ name: StaticString,
        _ detail: @autoclosure () -> String = "",
        body: () throws -> T
    ) rethrows -> T {
        guard isEnabled else { return try body() }
        let label = String(describing: name)
        // Materialized up front: `Logger`'s interpolation takes an escaping
        // autoclosure, which a non-escaping parameter cannot be captured by.
        let context = detail()
        let signpostState = signposter.beginInterval(name)
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
            signposter.endInterval(name, signpostState)
            if milliseconds >= 2 {
                logger.warning("SLOW \(label, privacy: .public) \(milliseconds, format: .fixed(precision: 1))ms \(context, privacy: .public)")
            } else {
                logger.debug("\(label, privacy: .public) \(milliseconds, format: .fixed(precision: 2))ms \(context, privacy: .public)")
            }
        }
        return try body()
    }
}
