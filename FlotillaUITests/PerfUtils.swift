import XCTest

/// Fast-accessibility-existence polling.
///
/// XCTest's `waitForExistence` carries a ~1.17s fixed overhead due to its
/// 1-second NSPredicate polling interval, regardless of whether the element
/// already exists or how short the timeout is. This helper polls `element.exists`
/// at ~50ms intervals, achieving the same logical result with dramatically
/// lower wall-clock cost.
func fastWait(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if element.exists { return true }
        usleep(50_000)  // 50 ms
    }
    return element.exists
}