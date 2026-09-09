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
final class SessionShutdownAndInitialSizeTests: XCTestCase {
    func testFlushLiveScrollbackPersistsAllBuffersSynchronously() async throws {
        let repo = try GRDBSessionRepository()
        let session = Session(
            title: "Flush Test",
            goal: "Goal",
            agent: .claudeCode,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .working,
            terminalScrollback: Data()
        )
        try repo.save(session)

        let store = AppStore(
            repository: repo,
            gitService: MockGitService(),
            processManager: SessionProcessManager(
                locator: AppLayerExecutableLocator(executable: URL(fileURLWithPath: "/bin/echo")),
                processFactory: RecordingProcessFactory()
            ),
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp") }
        )

        store.appendTerminalOutput(Data("output-to-flush\n".utf8), toSessionID: session.id)

        // Calling flushLiveScrollback immediately forces persistence without waiting for debounce
        store.flushLiveScrollback()

        let (_, loadedSessions) = try repo.loadAll()
        let loaded = try XCTUnwrap(loadedSessions.first(where: { $0.id == session.id }))
        XCTAssertEqual(String(decoding: loaded.terminalScrollback, as: UTF8.self), "output-to-flush\n")
    }

}
