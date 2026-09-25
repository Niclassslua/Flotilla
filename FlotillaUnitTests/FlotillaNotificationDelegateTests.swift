import XCTest
@testable import Flotilla

final class FlotillaNotificationDelegateTests: XCTestCase {
    func testSessionIDParsing() {
        let sessionID = UUID()
        let cases: [(userInfo: [AnyHashable: Any], expected: UUID?)] = [
            (["sessionID": sessionID.uuidString], sessionID),
            ([:], nil),
            (["sessionID": "not-a-uuid"], nil),
            (["sessionID": 42], nil),
        ]

        for entry in cases {
            XCTAssertEqual(
                FlotillaNotificationDelegate.sessionID(from: entry.userInfo),
                entry.expected
            )
        }
    }

    func testPresentationOptionsFollowForegroundSetting() {
        XCTAssertEqual(
            FlotillaNotificationDelegate.presentationOptions(shouldPresentInForeground: false),
            []
        )
        XCTAssertEqual(
            FlotillaNotificationDelegate.presentationOptions(shouldPresentInForeground: true),
            [.banner, .sound]
        )
    }
}
