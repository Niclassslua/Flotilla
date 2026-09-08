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
final class StartupCheckViewModelTests: XCTestCase {
    func testMissingOpenCodeIsDetectedButExcludedFromWarningItems() {
        let viewModel = StartupCheckViewModel(
            locator: SelectiveExecutableLocator(
                availableNames: ["git", "tmux", "gh", "claude", "codex", "agy"]
            )
        )

        XCTAssertEqual(viewModel.missingAgents, [.openCode])
        XCTAssertTrue(viewModel.warningItems.isEmpty)
    }

    func testOtherMissingAgentStillAppearsInWarningItems() {
        let viewModel = StartupCheckViewModel(
            locator: SelectiveExecutableLocator(
                availableNames: ["git", "tmux", "gh", "claude", "opencode", "agy"]
            )
        )

        XCTAssertEqual(viewModel.missingAgents, [.codexCLI])
        XCTAssertEqual(viewModel.warningItems, [AgentKind.codexCLI.displayName])
    }
}
