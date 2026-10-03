import XCTest
import SessionKit
@testable import Flotilla

final class HostAppAwarenessTests: XCTestCase {
    private let host = HostAppAwareness.Host(name: "Flotilla", bundleIdentifier: "com.niclassslua.flotilla")

    func testClaudeGetsInstructionsAppendedToItsSystemPrompt() {
        XCTAssertEqual(
            HostAppAwareness.launchArguments(for: .claudeCode, host: host),
            ["--append-system-prompt", HostAppAwareness.instructions(for: host)]
        )
    }

    func testCodexGetsInstructionsAsAQuotedDeveloperInstructionsOverride() throws {
        let arguments = HostAppAwareness.launchArguments(for: .codexCLI, host: host)
        XCTAssertEqual(arguments.first, "--config")
        let assignment = try XCTUnwrap(arguments.last)
        let prefix = "developer_instructions="
        XCTAssertTrue(assignment.hasPrefix(prefix))
        // The backticks and em dashes in the text must survive the quoting.
        let literal = Data(assignment.dropFirst(prefix.count).utf8)
        let decoded = try JSONSerialization.jsonObject(with: literal, options: .fragmentsAllowed) as? String
        XCTAssertEqual(decoded, HostAppAwareness.instructions(for: host))
    }

    func testAgentsWithoutASystemPromptFlagGetNoArguments() {
        for agent in [AgentKind.openCode, .antigravity, .cursorAgent] {
            XCTAssertEqual(HostAppAwareness.launchArguments(for: agent, host: host), [], "\(agent)")
        }
    }
}
