import Foundation
import Observation
import SettingsKit
import DesignSystem

@Observable
@MainActor
final class SettingsViewModel {
    private let store: SettingsStoring

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

    init(store: SettingsStoring) {
        self.store = store
        let loaded = store.load()
        self.settings = loaded
        FlotillaAccent.currentID = loaded.accentColor
    }
}
