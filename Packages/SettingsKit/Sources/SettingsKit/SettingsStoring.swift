import Foundation

public protocol SettingsStoring: Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

private extension AppSettings {
    static let schemaVersion: UInt = 1
}

/// Real persistence via `UserDefaults` — appropriate for a small set of
/// preference values (no need for SQLite here).
public final class UserDefaultsSettingsStore: SettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "com.flotilla.appSettings"
    private let defaultWorktreeBaseDirectory: String

    public init(defaults: UserDefaults = .standard, defaultWorktreeBaseDirectory: String) {
        self.defaults = defaults
        self.defaultWorktreeBaseDirectory = defaultWorktreeBaseDirectory
    }

    public func load() -> AppSettings {
        let storedVersion = defaults.integer(forKey: "\(key).schemaVersion")
        let currentVersion = AppSettings.schemaVersion

        guard storedVersion == currentVersion,
              let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            // Schema mismatch or corrupt data: return a minimal valid settings
            // object rather than erasing everything the user has configured.
            if storedVersion != currentVersion {
                // Schema version changed — return defaults but could later
                // add migration logic here.
            }
            return AppSettings(worktreeBaseDirectory: defaultWorktreeBaseDirectory)
        }
        return decoded
    }

    public func save(_ settings: AppSettings) {
        var encoded = defaults.data(forKey: key) ?? Data()
        let newData = try? JSONEncoder().encode(settings)
        guard let data = newData else { return }
        defaults.set(data, forKey: key)
        defaults.set(AppSettings.schemaVersion, forKey: "\(key).schemaVersion")
    }
}
