import XCTest
import SessionKit
import ProcessKit
import GitKit
import PersistenceKit
import SettingsKit
import TerminalKit
import HooksKit
@testable import Flotilla

final class StatusPresentationTests: XCTestCase {
    func testWaitingReasonsHaveActionableLabelsAndGlyphs() {
        XCTAssertEqual(StatusPresentation.label(for: .waitingForInput, waitingReason: .permission), "Needs Permission")
        XCTAssertEqual(StatusPresentation.label(for: .waitingForInput, waitingReason: .question), "Needs Answer")
        XCTAssertEqual(StatusPresentation.label(for: .waitingForInput, waitingReason: .planApproval), "Plan Ready")
        XCTAssertEqual(StatusPresentation.glyph(for: .waitingForInput, waitingReason: .permission), "lock.open")
        XCTAssertEqual(StatusPresentation.glyph(for: .waitingForInput, waitingReason: .question), "questionmark.bubble")
        XCTAssertEqual(StatusPresentation.glyph(for: .waitingForInput, waitingReason: .planApproval), "list.clipboard")
    }

    func testUnknownWaitingReasonKeepsLegacyLabel() {
        XCTAssertEqual(StatusPresentation.label(for: .waitingForInput), "Waiting for Input")
    }
}
