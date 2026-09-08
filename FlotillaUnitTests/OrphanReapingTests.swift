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
final class OrphanReapingTests: XCTestCase {
    func testOrphanTmuxSessionReapingKillsOnlyUnknownSessions() {
        let terminator = MockTmuxSessionTerminator()
        let knownUUID = UUID()
        let orphanUUID = UUID()

        terminator.stubbedSessions = [
            "flotilla-\(knownUUID.uuidString)",
            "flotilla-\(orphanUUID.uuidString)",
            "other-user-session"
        ]

        let locator = AppLayerExecutableLocator(executable: URL(fileURLWithPath: "/bin/echo"), tmuxExecutable: URL(fileURLWithPath: "/usr/bin/tmux"))
        let manager = SessionProcessManager(
            locator: locator,
            processFactory: RecordingProcessFactory(),
            tmuxTerminator: terminator
        )

        manager.reapOrphanTmuxSessions(knownSessionIDs: [knownUUID])

        XCTAssertEqual(terminator.killedSessions, ["flotilla-\(orphanUUID.uuidString)"])
    }
}
