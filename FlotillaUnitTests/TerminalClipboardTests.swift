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
final class TerminalClipboardTests: XCTestCase {
    func testClipboardCopyWritesLossyUTF8Safely() {
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
            accessibilityIdentifier: "ClipboardTest"
        )
        let terminalView = controller.terminalView(for: .session)

        // Seed clipboard with a known string
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("initial-clip", forType: .string)

        // Calling clipboardCopy with empty data should NOT clear the existing pasteboard
        controller.clipboardCopy(source: terminalView, content: Data())
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "initial-clip")

        // Calling clipboardCopy with valid data writes to pasteboard
        controller.clipboardCopy(source: terminalView, content: Data("hello-terminal".utf8))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "hello-terminal")
    }
}
