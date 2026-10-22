import Foundation

public protocol SettingsStoring: Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

/// A launch-scoped store that starts from known settings and deliberately
/// ignores saves. The owning view model still holds changes for the lifetime
/// of the process, but a subsequent launch starts cleanly again.
public struct EphemeralSettingsStore: SettingsStoring {
    private let initialSettings: AppSettings

    public init(defaultWorktreeBaseDirectory: String) {
        initialSettings = AppSettings(worktreeBaseDirectory: defaultWorktreeBaseDirectory)
    }

    public init(initialSettings: AppSettings) {
        self.initialSettings = initialSettings
    }

    public func load() -> AppSettings {
        initialSettings
    }

    public func save(_: AppSettings) {}
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
        let versionKey = "\(key).schemaVersion"
        // `integer(forKey:)` is 0 when the key is absent — that must not wipe
        // a still-valid JSON payload that predates the version stamp.
        let hasVersion = defaults.object(forKey: versionKey) != nil
        let storedVersion = UInt(defaults.integer(forKey: versionKey))
        let currentVersion = AppSettings.schemaVersion

        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings(worktreeBaseDirectory: defaultWorktreeBaseDirectory)
        }

        if !hasVersion || storedVersion != currentVersion {
            // Payload decoded; stamp (or migrate-noop) the current version so
            // the next load does not treat a missing key as a wipe signal.
            defaults.set(currentVersion, forKey: versionKey)
        }
        return decoded
    }

    public func save(_ settings: AppSettings) {
        let _ = defaults.data(forKey: key) ?? Data()
        let newData = try? JSONEncoder().encode(settings)
        guard let data = newData else { return }
        defaults.set(data, forKey: key)
        defaults.set(AppSettings.schemaVersion, forKey: "\(key).schemaVersion")
    }
}
