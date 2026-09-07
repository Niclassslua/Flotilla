import Foundation

/// Produces environments for commands launched outside Flotilla.
///
/// Xcode injects debugger, preview, view-hierarchy, and GPU-capture settings
/// into the app process. Those settings belong to Flotilla itself: forwarding
/// them to tmux or an agent can make unrelated executables load Xcode-only
/// dylibs, and a long-lived tmux server can retain that poisoned environment
/// after the debugging session ends.
enum ChildProcessEnvironment {
    private static let blockedKeys: Set<String> = [
        "CA_ASSERT_MAIN_THREAD_TRANSACTIONS",
        "CA_DEBUG_TRANSACTIONS",
        "IDE_DISABLED_OS_ACTIVITY_DT_MODE",
        "LLVM_PROFILE_FILE",
        "NSUnbufferedIO",
        "OS_ACTIVITY_DT_MODE",
        "OS_ACTIVITY_TOOLS_OVERSIZE",
        "OS_ACTIVITY_TOOLS_PRIVACY",
        "PERFC_SUPPRESS_SYSTEM_REPORTS",
        "SQLITE_ENABLE_THREAD_ASSERTIONS",
        "SWIFTUI_VIEW_DEBUG",
        "XCODE_RUNNING_FOR_PREVIEWS",
        "XCInjectBundleInto",
        "XCTestBundlePath",
        "XCTestConfigurationFilePath",
        "XCTestSessionIdentifier",
        "XCTestSessionIdentifierPrototype",
        "XPC_FLAGS",
        "XPC_SERVICE_NAME",
        "__CFBundleIdentifier",
        "__XPC_LLVM_PROFILE_FILE",
    ]

    private static let blockedPrefixes = [
        "DYLD_",
        "DYMTL_",
        "GPUTOOLS_",
        "METAL_",
        "MTL_",
        "MTLREPLAYER_",
        "__XCODE_",
        "__XPC_DYLD_",
    ]

    static func sanitized(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in !isBlocked(key) }
    }

    static func blockedVariableNames(in environment: [String: String]) -> Set<String> {
        Set(environment.keys.filter(isBlocked))
    }

    /// Foundation `Process` otherwise inherits Flotilla's complete environment
    /// and current working directory at `run()`. Spawning helper commands with
    /// `currentDirectoryURL = /` prevents a daemon (such as the tmux server)
    /// from inheriting a deletable worktree directory as its working directory.
    static func makeProcess() -> Process {
        let process = Process()
        process.environment = sanitized(ProcessInfo.processInfo.environment)
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        return process
    }

    private static func isBlocked(_ key: String) -> Bool {
        blockedKeys.contains(key)
            || blockedPrefixes.contains(where: key.hasPrefix)
    }
}
