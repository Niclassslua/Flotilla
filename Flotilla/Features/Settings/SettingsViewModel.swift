import Foundation
import Observation
import SettingsKit
import DesignSystem
import CoreGraphics
import AppKit

@Observable
@MainActor
final class SettingsViewModel {
    private let store: SettingsStoring
    @ObservationIgnored private let checkScreenCapture: @MainActor () -> Bool
    @ObservationIgnored private let requestScreenCapture: @MainActor () -> Bool
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            FlotillaAccent.currentID = settings.accentColor
            store.save(settings)
        }
    }

    /// Deletes the commit attribution kept on this Mac. Set by the app once its
    /// store exists; `nil` wherever there is no store.
    @ObservationIgnored var deleteLocalAttributionRecords: (@MainActor () -> Void)?

    private(set) var hasScreenRecordingPermission: Bool = false

    init(
        store: SettingsStoring,
        checkScreenCapture: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
        requestScreenCapture: @escaping @MainActor () -> Bool = { CGRequestScreenCaptureAccess() },
        openURL: @escaping @MainActor (URL) -> Void = { url in NSWorkspace.shared.open(url) }
    ) {
        self.store = store
        self.checkScreenCapture = checkScreenCapture
        self.requestScreenCapture = requestScreenCapture
        self.openURL = openURL
        let loaded = store.load()
        self.settings = loaded
        FlotillaAccent.currentID = loaded.accentColor
        self.hasScreenRecordingPermission = checkScreenCapture()
    }

    func checkScreenRecordingPermission() {
        hasScreenRecordingPermission = checkScreenCapture()
    }

    func requestScreenRecordingPermission() {
        let granted = requestScreenCapture()
        hasScreenRecordingPermission = granted || checkScreenCapture()
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        openURL(url)
    }
}
