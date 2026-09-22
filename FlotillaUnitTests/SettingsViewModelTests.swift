import XCTest
import SettingsKit
@testable import Flotilla

@MainActor
final class SettingsViewModelTests: XCTestCase {
    private func makeStore() -> any SettingsStoring {
        EphemeralSettingsStore(initialSettings: AppSettings())
    }

    func testInitializesPermissionFromCheckClosure() {
        let store = makeStore()
        let vmGranted = SettingsViewModel(
            store: store,
            checkScreenCapture: { true }
        )
        XCTAssertTrue(vmGranted.hasScreenRecordingPermission)

        let vmDenied = SettingsViewModel(
            store: store,
            checkScreenCapture: { false }
        )
        XCTAssertFalse(vmDenied.hasScreenRecordingPermission)
    }

    func testCheckScreenRecordingPermissionUpdatesState() {
        let store = makeStore()
        var currentStatus = false
        let vm = SettingsViewModel(
            store: store,
            checkScreenCapture: { currentStatus }
        )
        XCTAssertFalse(vm.hasScreenRecordingPermission)

        currentStatus = true
        vm.checkScreenRecordingPermission()
        XCTAssertTrue(vm.hasScreenRecordingPermission)

        currentStatus = false
        vm.checkScreenRecordingPermission()
        XCTAssertFalse(vm.hasScreenRecordingPermission)
    }

    func testRequestScreenRecordingPermissionInvokesRequest() {
        let store = makeStore()
        var requestCalled = false
        var preflightStatus = false
        let vm = SettingsViewModel(
            store: store,
            checkScreenCapture: { preflightStatus },
            requestScreenCapture: {
                requestCalled = true
                preflightStatus = true
                return true
            }
        )

        XCTAssertFalse(vm.hasScreenRecordingPermission)
        XCTAssertFalse(requestCalled)

        vm.requestScreenRecordingPermission()

        XCTAssertTrue(requestCalled)
        XCTAssertTrue(vm.hasScreenRecordingPermission)
    }

    func testOpenScreenRecordingSettingsOpensCorrectURL() {
        let store = makeStore()
        var openedURL: URL?
        let vm = SettingsViewModel(
            store: store,
            openURL: { url in openedURL = url }
        )

        vm.openScreenRecordingSettings()

        XCTAssertEqual(
            openedURL?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }

    func testDefaultCheckClosureRunsWithoutError() {
        let store = makeStore()
        let vm = SettingsViewModel(store: store)
        _ = vm.hasScreenRecordingPermission
    }
}
