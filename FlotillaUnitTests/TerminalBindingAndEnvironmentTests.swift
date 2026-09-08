import XCTest
import SessionKit
import ProcessKit
import GitKit
import PersistenceKit
import SettingsKit
import TerminalKit
import HooksKit
@testable import Flotilla

@MainActor
final class TerminalBindingAndEnvironmentTests: XCTestCase {
    func testTerminalControllerRebindSwapsProcess() async throws {
        let proc1 = MockPTYProcess()
        try proc1.start(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )

        let controller = TerminalController(
            sessionID: UUID(),
            process: proc1,
            accessibilityIdentifier: "RebindTest"
        )
        XCTAssertEqual(controller.processID, proc1.id)

        let proc2 = MockPTYProcess()
        try proc2.start(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )

        controller.rebind(process: proc2)
        XCTAssertEqual(controller.processID, proc2.id)
    }

    func testVisibleScreenTextReadsAuthoritativeView() {
        let process = MockPTYProcess()
        try? process.start(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )

        let controller = TerminalController(
            sessionID: UUID(),
            process: process,
            accessibilityIdentifier: "VisibleTextTest"
        )

        controller.makeAuthoritative(.session)
        XCTAssertNotNil(controller.visibleScreenText())
    }

    func testEnvironmentVariablesForwardedViaEFlags() {
        let env = ["MY_API_KEY": "secret_val", "CUSTOM_PATH": "/custom/bin", "TMUX": "should_be_stripped"]
        let launch = TmuxSessionWrapping.wrap(
            agentExecutable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"],
            environment: env,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            sessionID: UUID(),
            tmuxExecutable: URL(fileURLWithPath: "/usr/bin/tmux")
        )

        XCTAssertTrue(launch.arguments.contains("-e"))
        XCTAssertTrue(launch.arguments.contains("MY_API_KEY=secret_val"))
        XCTAssertTrue(launch.arguments.contains("CUSTOM_PATH=/custom/bin"))
        XCTAssertFalse(launch.arguments.contains("TMUX=should_be_stripped"))
    }
}
