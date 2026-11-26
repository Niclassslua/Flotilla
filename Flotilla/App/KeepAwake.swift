import Foundation

/// Manual "caffeinate": while on, holds an idle-system-sleep assertion so
/// agents keep running when the Mac is left alone. The display may still
/// sleep. Off on every launch on purpose — sleep is disabled only when asked.
@Observable @MainActor
final class KeepAwake {
    static let shared = KeepAwake()

    private var activity: NSObjectProtocol?

    var isOn: Bool { activity != nil }

    func toggle() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        } else {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "Flotilla keep-awake toggle"
            )
        }
    }
}
