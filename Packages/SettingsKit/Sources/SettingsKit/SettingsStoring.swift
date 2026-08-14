import Foundation

public protocol SettingsStoring: Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
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
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings(worktreeBaseDirectory: defaultWorktreeBaseDirectory)
        }
        return decoded
    }

    public func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
