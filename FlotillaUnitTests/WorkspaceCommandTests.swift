import XCTest
@testable import Flotilla

/// Guards the destination canon in `docs/ui-model.md` § 1.
@MainActor
final class WorkspaceCommandTests: XCTestCase {

    /// The palette shipped with two pairs of commands that landed in the same
    /// place — `.showOverview`/`.showProjects` both restored the Home
    /// selection, and `.showTerminal`/`.showSessions` both navigated to the
    /// fleet in Focus. A user picking between two labels for one outcome is
    /// choosing nothing, so a repeat is a defect rather than a convenience.
    func testNoTwoCommandsShareADestination() {
        var seen: [WorkspaceDestination: WorkspaceCommand] = [:]
        for command in WorkspaceCommand.allCases {
            guard let destination = command.destination else { continue }
            if let existing = seen[destination] {
                XCTFail("\(command) and \(existing) both go to \(destination)")
            }
            seen[destination] = command
        }
    }

    /// Commands that navigate declare where they land; commands that act do
    /// not. Without this, a new navigating command could skip `destination`
    /// and silently escape the uniqueness check above.
    func testOnlyActionCommandsHaveNoDestination() {
        let actions: Set<WorkspaceCommand> = [.newSession, .restoreSessions, .showSettings, .showShortcuts]
        for command in WorkspaceCommand.allCases {
            if actions.contains(command) {
                XCTAssertNil(command.destination, "\(command) is an action and should not declare a destination")
            } else {
                XCTAssertNotNil(command.destination, "\(command) navigates and must declare its destination")
            }
        }
    }

    /// Every palette entry needs both lines — the subtitle is what tells the
    /// two "go to" commands apart once they no longer share a destination.
    func testEveryCommandHasTitleAndSubtitle() {
        for command in WorkspaceCommand.allCases {
            XCTAssertFalse(command.title.isEmpty, "\(command) has no title")
            XCTAssertFalse(command.subtitle.isEmpty, "\(command) has no subtitle")
        }
    }
}
