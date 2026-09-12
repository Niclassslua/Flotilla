import XCTest

/// Throwaway diagnostic: measures per-query snapshot cost after launch.
@MainActor
final class ZZPerfProbeUITests: XCTestCase {
    func testSnapshotCost() {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()

        let row = app.descendants(matching: .any)[AXID.sessionRow("Fix login bug")].firstMatch
        _ = row.waitForExistence(timeout: 10)

        // Measure 10 repeated existence checks on a static element
        let t0 = Date()
        for _ in 0..<10 {
            _ = row.exists
        }
        let perQuery = Date().timeIntervalSince(t0) / 10
        print("PERFPROBE per-query exists: \(perQuery * 1000) ms")

        let t1 = Date()
        for _ in 0..<5 {
            _ = row.waitForExistence(timeout: 1)
        }
        print("PERFPROBE per waitForExistence: \(Date().timeIntervalSince(t1) / 5 * 1000) ms")

        // count descendants to gauge tree size
        let t2 = Date()
        let count = app.descendants(matching: .any).count
        print("PERFPROBE descendant count: \(count) in \(Date().timeIntervalSince(t2) * 1000) ms")

        // custom fast polling helper
        func fastWait(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if element.exists { return true }
                usleep(50_000)
            }
            return element.exists
        }
        let t3 = Date()
        for _ in 0..<5 {
            _ = fastWait(row, timeout: 1)
        }
        print("PERFPROBE per fastWait: \(Date().timeIntervalSince(t3) / 5 * 1000) ms")
    }
}
