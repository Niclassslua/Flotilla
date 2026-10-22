import Foundation

/// Pre-flight check so Flotilla (not a detached tmux child) is the process
/// that triggers macOS Files & Folders prompts — and so a Deny shows a clear
/// error instead of an agent crash or `git: Operation not permitted`.
enum ProtectedFolderAccess {
    struct Denied: LocalizedError, Equatable {
        let folderName: String

        var errorDescription: String? {
            "macOS blocked access to \(folderName). Allow Flotilla access to \(folderName) in System Settings → Privacy & Security → Files & Folders"
        }

        static let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
        )
    }

    /// Lists `url` so TCC attributes the request to Flotilla. Throws `Denied`
    /// on EPERM / no-permission. Missing paths are skipped — TCC only applies
    /// to folders that exist; callers handle not-found separately.
    static func requireReadable(_ url: URL) throws {
        fileScanLog.notice("requireReadable: \(url.path, privacy: .public)")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
        } catch {
            if isPermissionDenied(error) {
                throw Denied(folderName: folderName(containing: url) ?? url.lastPathComponent)
            }
            throw error
        }
    }

    static func folderName(containing url: URL) -> String? {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().standardizedFileURL.path
        let roots: [(String, String)] = [
            (home + "/Documents", "Documents"),
            (home + "/Desktop", "Desktop"),
            (home + "/Downloads", "Downloads"),
            (home + "/Library/Mobile Documents", "iCloud Drive"),
        ]
        for (prefix, name) in roots where path == prefix || path.hasPrefix(prefix + "/") {
            return name
        }
        return nil
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EPERM) || nsError.code == Int(EACCES) {
            return true
        }
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError
    }
}
