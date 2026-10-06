import XCTest
import ProcessKit
import AgentKit
import SettingsKit

final class SystemPTYProcessTests: XCTestCase {
    /// Smoke test against the real PTY implementation: spawns /bin/echo and
    /// confirms output actually flows back through the master fd.
    func testRealProcessProducesOutput() async throws {
        let process = SystemPTYProcess()
        try process.start(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello-from-pty"],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )

        var collected = Data()
        for await chunk in process.outputStream {
            collected.append(chunk)
            if String(decoding: collected, as: UTF8.self).contains("hello-from-pty") {
                break
            }
        }

        XCTAssertTrue(String(decoding: collected, as: UTF8.self).contains("hello-from-pty"))
    }

    /// A descriptor the parent opened without close-on-exec must not reach
    /// the child: agents run under a tmux server that outlives Flotilla, and
    /// a leaked companion-socket lock there disabled the phone bridge.
    func testChildDoesNotInheritParentDescriptors() async throws {
        let leaked = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThan(leaked, STDERR_FILENO)
        defer { close(leaked) }
        let process = SystemPTYProcess()
        try process.start(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "if [ -e /dev/fd/\(leaked) ]; then echo fd-leaked; else echo fd-closed; fi"],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )

        var collected = Data()
        for await chunk in process.outputStream {
            collected.append(chunk)
            let text = String(decoding: collected, as: UTF8.self)
            if text.contains("fd-leaked") || text.contains("fd-closed") { break }
        }

        XCTAssertTrue(String(decoding: collected, as: UTF8.self).contains("fd-closed"))
    }

    /// End-to-end regression for the black-and-white terminal bug: GUI-launched
    /// apps (Finder, Xcode's debugger) inherit `TERM=dumb` from launchd, and
    /// left untouched that reaches the agent CLI's real environment, whose
    /// color-support detection sees `dumb` and disables all color output.
    /// This exercises the full pipeline `CLIAgentProvider.launchPlan` feeds
    /// `SessionProcessManager.start` with — a real PTY spawning a real
    /// subprocess — rather than asserting on `AgentLaunchPlan` in isolation.
    func testAgentLaunchPlanEnvironmentReachesRealSubprocessWithUsableTerm() async throws {
        let plan = CLIAgentProvider(kind: .claudeCode, binaryName: "claude").launchPlan(
            goal: nil,
            settings: AppSettings(),
            baseEnvironment: ["TERM": "dumb", "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
        )

        let process = SystemPTYProcess()
        let stream = process.outputStream
        try process.start(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [],
            environment: plan.environment,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )

        // `env`'s output order follows the environment dictionary's iteration
        // order, which Swift does not guarantee — drain to actual process
        // exit (stream completion) rather than breaking on the first
        // expected substring, or a race could stop the read before a
        // not-yet-printed line has been flushed.
        var collected = Data()
        for await chunk in stream {
            collected.append(chunk)
            let str = String(decoding: collected, as: UTF8.self)
            if str.contains("TERM=xterm-256color") && str.contains("COLORTERM=truecolor") {
                break
            }
        }

        let printedEnvironment = String(decoding: collected, as: UTF8.self)
        XCTAssertTrue(printedEnvironment.contains("TERM=xterm-256color"))
        XCTAssertFalse(printedEnvironment.contains("TERM=dumb"))
        XCTAssertTrue(printedEnvironment.contains("COLORTERM=truecolor"))
    }

    /// Tests that the child process can receive SIGWINCH even when the calling
    /// thread (e.g. Swift concurrency / GCD thread) has SIGWINCH blocked.
    func testChildReceivesSIGWINCHEvenWhenCallingThreadBlocksIt() async throws {
        var blockMask = sigset_t()
        sigemptyset(&blockMask)
        sigaddset(&blockMask, SIGWINCH)
        var oldMask = sigset_t()
        pthread_sigmask(SIG_BLOCK, &blockMask, &oldMask)
        defer {
            pthread_sigmask(SIG_SETMASK, &oldMask, nil)
        }

        let process = SystemPTYProcess()
        try process.start(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap 'echo GOTWINCH' WINCH; echo READY; while :; do sleep 0.2; done"],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )
        defer {
            process.terminate()
        }

        let stream = process.outputStream
        let accumulator = LockedStringAccumulator()

        let task = Task {
            for await chunk in stream {
                accumulator.append(String(decoding: chunk, as: UTF8.self))
            }
        }

        // Wait until the child is ready and listening for traps
        for _ in 0..<50 {
            if accumulator.contains("READY") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(accumulator.contains("READY"), "Shell script must start and output READY")

        // Trigger resize which fires SIGWINCH from the kernel to the PTY foreground process group
        process.resize(PTYSize(cols: 100, rows: 30))

        for _ in 0..<50 {
            if accumulator.contains("GOTWINCH") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(accumulator.contains("GOTWINCH"), "Child must receive SIGWINCH despite parent thread blocking it")
        task.cancel()
    }
}

private final class LockedStringAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ string: String) {
        lock.lock()
        defer { lock.unlock() }
        buffer += string
    }

    func contains(_ needle: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return buffer.contains(needle)
    }
}

final class StartupEnvironmentCheckerTests: XCTestCase {
    private struct FakeLocator: ExecutableLocating {
        let available: Set<String>
        func locate(_ name: String) -> URL? {
            available.contains(name) ? URL(fileURLWithPath: "/usr/local/bin/\(name)") : nil
        }
    }

    func testReportsFoundAndMissingSeparately() {
        let locator = FakeLocator(available: ["claude", "tmux"])
        let checker = StartupEnvironmentChecker(locator: locator)

        let report = checker.check(tools: ["claude", "codex", "opencode", "tmux", "gh"])

        XCTAssertTrue(report.isInstalled("claude"))
        XCTAssertTrue(report.isInstalled("tmux"))
        XCTAssertFalse(report.isInstalled("codex"))
        XCTAssertEqual(Set(report.missingTools), ["codex", "opencode", "gh"])
    }

    func testPATHExecutableLocatorFindsRealBinary() {
        // /bin/echo exists on every macOS install; use it as a real-filesystem check.
        let locator = PATHExecutableLocator(pathEnvironment: "/bin:/usr/bin")
        XCTAssertNotNil(locator.locate("echo"))
        XCTAssertNil(locator.locate("definitely-not-a-real-binary-xyz"))
    }

    func testPATHLocatorFindsUserLocalBinaryForFinderStyleEmptyPATH() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("flotilla-locator-\(UUID().uuidString)")
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
        let gh = bin.appendingPathComponent("gh")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: gh)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        defer { try? FileManager.default.removeItem(at: home) }

        let locator = PATHExecutableLocator(pathEnvironment: "", homeDirectory: home)
        XCTAssertEqual(locator.locate("gh"), gh)
    }

    func testPATHLocatorFindsConfiguredHomebrewStyleDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flotilla-homebrew-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let tmux = bin.appendingPathComponent("tmux")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: tmux)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmux.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = PATHExecutableLocator(
            pathEnvironment: "",
            homeDirectory: root.appendingPathComponent("home"),
            additionalSearchPaths: [bin.path]
        )
        XCTAssertEqual(locator.locate("tmux"), tmux)
    }

    func testPATHLocatorRejectsNonExecutableFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flotilla-nonexec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let candidate = root.appendingPathComponent("flotilla-nonexec-tool")
        try Data("not executable".utf8).write(to: candidate)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = PATHExecutableLocator(
            pathEnvironment: "",
            additionalSearchPaths: [root.path]
        )
        XCTAssertNil(locator.locate("flotilla-nonexec-tool"))
    }
}
