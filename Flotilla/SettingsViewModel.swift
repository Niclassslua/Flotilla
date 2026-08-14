import Foundation
import Observation
import SettingsKit

@Observable
@MainActor
final class SettingsViewModel {
    private let store: SettingsStoring

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            store.save(settings)
        }
    }

    init(store: SettingsStoring) {
        self.store = store
        self.settings = store.load()
    }
}
