import AppKit
import CoreGraphics

/// Samples whether the Mac is in use when an attention edge arrives.
/// The clock and signal readers are injected so the policy can be tested.
@MainActor
final class PresenceMonitor {
    private let isAppActive: () -> Bool
    private let idleSeconds: () -> TimeInterval
    private let now: () -> Date
    private var screenLocked = false
    nonisolated(unsafe) private var lockObserver: NSObjectProtocol?
    nonisolated(unsafe) private var unlockObserver: NSObjectProtocol?
    private var lastSampleAt: Date?
    private var lastSample: Bool = false

    init(
        isAppActive: @escaping () -> Bool = { NSApp.isActive },
        idleSeconds: @escaping () -> TimeInterval = {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)
        },
        now: @escaping () -> Date = Date.init,
        observeScreenLock: Bool = true
    ) {
        self.isAppActive = isAppActive
        self.idleSeconds = idleSeconds
        self.now = now
        if observeScreenLock {
            lockObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.screenLocked = true }
            }
            unlockObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.screenLocked = false }
            }
        }
    }

    deinit {
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
        if let unlockObserver { DistributedNotificationCenter.default().removeObserver(unlockObserver) }
    }

    var isAway: Bool {
        let sampledAt = now()
        if let lastSampleAt, sampledAt.timeIntervalSince(lastSampleAt) < 1 { return lastSample }
        let away = screenLocked || !isAppActive() || idleSeconds() > 45
        lastSampleAt = sampledAt
        lastSample = away
        return away
    }

    /// Updates the same state as the distributed lock notifications; useful
    /// for deterministic policy tests without posting process-wide events.
    func setScreenLockedForTesting(_ locked: Bool) {
        screenLocked = locked
        lastSampleAt = nil
    }
}
