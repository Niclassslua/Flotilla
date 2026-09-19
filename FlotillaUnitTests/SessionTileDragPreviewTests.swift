import XCTest
import SwiftUI
import SessionKit
import DesignSystem
@testable import Flotilla

final class SessionTileDragPreviewTests: XCTestCase {
    private func makeSession(title: String, status: SessionStatus = .working, agent: AgentKind = .claudeCode) -> Session {
        Session(
            title: title,
            goal: "Goal",
            agent: agent,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: status
        )
    }

    @MainActor
    func testTileDragPreviewRendersFullSessionTitle() {
        let longTitle = "Feature: Implement comprehensive session handoff transaction between agents"
        let session = makeSession(title: longTitle)

        let preview = TileDragPreview(session: session)
        XCTAssertEqual(preview.session.title, longTitle)
        XCTAssertEqual(preview.session.agent, .claudeCode)
        XCTAssertEqual(preview.session.status, .working)
    }

    @MainActor
    func testTileDragPreviewPreservesSessionAttributes() {
        let title = "bugfix/issue-402-naming-collision"
        let session = makeSession(title: title, status: .waitingForInput, agent: .codexCLI)

        let preview = TileDragPreview(session: session)
        XCTAssertEqual(preview.session.title, title)
        XCTAssertEqual(preview.session.status, .waitingForInput)
        XCTAssertEqual(preview.session.agent, .codexCLI)
    }
}
