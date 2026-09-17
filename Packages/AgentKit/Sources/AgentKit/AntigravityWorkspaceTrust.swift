import Foundation

/// Manages workspace trust configuration for the Antigravity CLI (`agy`).
///
/// Antigravity prompts interactively with:
/// ```text
/// Accessing workspace:
/// <path>
/// Do you trust the contents of this project?
/// Antigravity CLI requires permission to read, edit, and execute files here.
/// > Yes, I trust this folder
///   No, exit
/// ```
/// whenever it is launched inside a workspace whose exact path is not recorded in
/// `~/.gemini/antigravity-cli/settings.json` under `trustedWorkspaces`.
///
/// Flotilla creates on-demand sessions and isolated git worktrees. To prevent this
/// blocking confirmation dialog and allow autonomous agent startup, this helper
/// ensures the session's workspace path (including standardized and symlink-resolved
/// variants) is recorded in `trustedWorkspaces` before launching the agent.
public struct AntigravityWorkspaceTrust: Sendable {
    private static let inProcessLock = NSLock()

    public enum Error: Swift.Error, Equatable {
        case trustedWorkspacesIsNotAnArray
    }

    /// Default directory containing Antigravity settings (`~/.gemini/antigravity-cli`),
    /// customizable via the `JETSKI_APP_DATA_DIR` environment variable.
    public static var defaultSettingsDirectory: URL {
        if let customDir = ProcessInfo.processInfo.environment["JETSKI_APP_DATA_DIR"], !customDir.isEmpty {
            return URL(fileURLWithPath: customDir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
    }

    /// Default URL for Antigravity's `settings.json`.
    public static func defaultSettingsURL() -> URL {
        defaultSettingsDirectory.appendingPathComponent("settings.json", isDirectory: false)
    }

    /// Resolves candidate path representations for a workspace URL to ensure matching
    /// regardless of symlinks or trailing slashes.
    public static func candidatePaths(for workspace: URL) -> [String] {
        let standardPath = workspace.standardizedFileURL.path
        let resolvedPath = workspace.resolvingSymlinksInPath().path
        let rawPath = workspace.path

        var candidates: [String] = []
        for path in [rawPath, standardPath, resolvedPath] {
            let normalized = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
            if !normalized.isEmpty && !candidates.contains(normalized) {
                candidates.append(normalized)
            }
        }
        return candidates
    }

    /// Ensures the workspace path and its canonical forms are added to `trustedWorkspaces`
    /// in Antigravity's `settings.json`.
    ///
    /// - Parameters:
    ///   - workspace: The directory URL of the workspace to trust.
    ///   - settingsURL: An optional custom URL to `settings.json` (defaults to `defaultSettingsURL()`).
    /// - Returns: `true` if `settings.json` was updated, `false` if all candidate paths were already trusted.
    @discardableResult
    public static func ensureTrusted(
        workspace: URL,
        settingsURL: URL? = nil
    ) throws -> Bool {
        let targetURL = settingsURL ?? defaultSettingsURL()
        let directoryURL = targetURL.deletingLastPathComponent()

        let candidates = candidatePaths(for: workspace)
        guard !candidates.isEmpty else { return false }

        inProcessLock.lock()
        defer { inProcessLock.unlock() }

        // Acquire an advisory lock file for cross-process synchronization
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let lockURL = directoryURL.appendingPathComponent(".flotilla-trust.lock", isDirectory: false)
        if !FileManager.default.fileExists(atPath: lockURL.path) {
            FileManager.default.createFile(atPath: lockURL.path, contents: nil)
        }

        let handle = try? FileHandle(forUpdating: lockURL)
        defer { try? handle?.close() }
        let fd = handle?.fileDescriptor
        if let fd {
            _ = Darwin.lockf(fd, F_LOCK, 0)
        }
        defer {
            if let fd {
                _ = Darwin.lockf(fd, F_ULOCK, 0)
            }
        }

        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: targetURL.path) {
            let data = try Data(contentsOf: targetURL)
            if let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = parsed
            } else {
                // If the file exists but isn't a valid JSON object, fail safe without overwriting
                return false
            }
        }

        var trusted: [String]
        if let value = root["trustedWorkspaces"] {
            guard let existing = value as? [String] else {
                // Do not silently replace a setting whose schema we do not
                // understand. Antigravity may have migrated this field, or a
                // user may need to repair it manually.
                throw Error.trustedWorkspacesIsNotAnArray
            }
            trusted = existing
        } else {
            trusted = []
        }
        var modified = false

        for candidate in candidates {
            if !trusted.contains(candidate) {
                trusted.append(candidate)
                modified = true
            }
        }

        guard modified else {
            return false
        }

        root["trustedWorkspaces"] = trusted

        let outputData = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try outputData.write(to: targetURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)

        return true
    }
}
