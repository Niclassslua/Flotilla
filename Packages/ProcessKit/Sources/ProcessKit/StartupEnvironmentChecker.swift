import Foundation

public protocol ExecutableLocating: Sendable {
    func locate(_ name: String) -> URL?
}

/// Locates command-line tools in both the inherited environment and the
/// conventional install locations used by Finder-launched macOS apps.
/// Finder does not start applications through an interactive shell, so its
/// `PATH` commonly omits Homebrew and user-local bins even though Terminal
/// can find the same tools.
public struct PATHExecutableLocator: ExecutableLocating, @unchecked Sendable {
    private let searchPaths: [String]
    private let fileManager: FileManager

    public init(
        pathEnvironment: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        additionalSearchPaths: [String] = [],
        fileManager: FileManager = .default
    ) {
        self.searchPaths = Self.searchDirectories(
            pathEnvironment: pathEnvironment,
            homeDirectory: homeDirectory,
            additionalSearchPaths: additionalSearchPaths
        )
        self.fileManager = fileManager
    }

    /// PATH suitable for processes launched from Finder as well as Terminal.
    /// The original ordering is retained, duplicates are removed, and common
    /// Homebrew/user-local locations are appended so child tools such as gh
    /// and tmux are available to the launched agent—not merely detectable by
    /// Flotilla's startup check.
    public static func augmentedPATH(
        pathEnvironment: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        searchDirectories(
            pathEnvironment: pathEnvironment,
            homeDirectory: homeDirectory,
            additionalSearchPaths: []
        ).joined(separator: ":")
    }

    private static func searchDirectories(
        pathEnvironment: String,
        homeDirectory: URL,
        additionalSearchPaths: [String]
    ) -> [String] {
        let inherited = pathEnvironment.split(separator: ":").map(String.init)
        let conventional = [
            homeDirectory.appendingPathComponent(".local/bin").path,
            homeDirectory.appendingPathComponent(".cargo/bin").path,
            homeDirectory.appendingPathComponent("bin").path,
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        var seen = Set<String>()
        return (additionalSearchPaths + inherited + conventional).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
    }

    public func locate(_ name: String) -> URL? {
        if name.contains("/"), fileManager.isExecutableFile(atPath: name) {
            return URL(fileURLWithPath: name)
        }
        for directory in searchPaths {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: candidate.path) else { continue }
            return candidate
        }
        return nil
    }
}

public struct StartupReport: Equatable {
    public var foundTools: [String: URL]
    public var missingTools: [String]

    public init(foundTools: [String: URL], missingTools: [String]) {
        self.foundTools = foundTools
        self.missingTools = missingTools
    }

    public func isInstalled(_ name: String) -> Bool {
        foundTools[name] != nil
    }
}

/// Non-blocking startup check: reports what's installed/missing, never
/// throws, and never prevents the app from continuing to launch.
public struct StartupEnvironmentChecker {
    private let locator: ExecutableLocating

    public init(locator: ExecutableLocating = PATHExecutableLocator()) {
        self.locator = locator
    }

    public func check(tools: [String]) -> StartupReport {
        var found: [String: URL] = [:]
        var missing: [String] = []
        for tool in tools {
            if let url = locator.locate(tool) {
                found[tool] = url
            } else {
                missing.append(tool)
            }
        }
        return StartupReport(foundTools: found, missingTools: missing)
    }
}
