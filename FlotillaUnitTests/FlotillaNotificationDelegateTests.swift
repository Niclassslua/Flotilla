import XCTest
@testable import Flotilla

final class FlotillaNotificationDelegateTests: XCTestCase {
    func testExtractsSessionIDFromValidUserInfo() {
        let sessionID = UUID()
        let userInfo: [AnyHashable: Any] = ["sessionID": sessionID.uuidString]

        XCTAssertEqual(FlotillaNotificationDelegate.sessionID(from: userInfo), sessionID)
    }

    func testReturnsNilWhenSessionIDKeyIsMissing() {
        XCTAssertNil(FlotillaNotificationDelegate.sessionID(from: [:]))
    }

    func testReturnsNilWhenValueIsNotAValidUUIDString() {
        let userInfo: [AnyHashable: Any] = ["sessionID": "not-a-uuid"]
        XCTAssertNil(FlotillaNotificationDelegate.sessionID(from: userInfo))
    }

    func testReturnsNilWhenValueIsWrongType() {
        let userInfo: [AnyHashable: Any] = ["sessionID": 42]
        XCTAssertNil(FlotillaNotificationDelegate.sessionID(from: userInfo))
    }
}
