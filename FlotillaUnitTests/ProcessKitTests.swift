import XCTest
import ProcessKit
import AgentKit
import SettingsKit

final class MockPTYProcessTests: XCTestCase {
    func testStartRecordsInvocationAndMarksRunning() throws {
        let mock = MockPTYProcess()
        let exe = URL(fileURLWithPath: "/bin/echo")
        try mock.start(
            executable: exe,
            arguments: ["hello"],
            environment: ["FOO": "BAR"],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )

        XCTAssertTrue(mock.isRunning)
        XCTAssertEqual(mock.startCallCount, 1)
        XCTAssertEqual(mock.startedExecutable, exe)
        XCTAssertEqual(mock.startedArguments, ["hello"])
        XCTAssertEqual(mock.startedEnvironment["FOO"], "BAR")
        XCTAssertEqual(mock.lastSize, PTYSize(cols: 80, rows: 24))
    }

    func testStartingTwiceThrows() throws {
        let mock = MockPTYProcess()
        try mock.start(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )
        XCTAssertThrowsError(try mock.start(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )) { error in
            XCTAssertEqual(error as? PTYProcessError, .alreadyRunning)
        }
    }

    func testFailureToStartLeavesProcessNotRunning() {
        let mock = MockPTYProcess()
        mock.shouldFailToStart = true
        XCTAssertThrowsError(try mock.start(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )) { error in
            XCTAssertEqual(error as? PTYProcessError, .failedToOpenPTY)
        }
        XCTAssertFalse(mock.isRunning)
    }

    func testSendRecordsInput() throws {
        let mock = MockPTYProcess()
        try mock.start(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )
        mock.send(input: Data("ls\n".utf8))
        XCTAssertEqual(mock.sentInput, [Data("ls\n".utf8)])
    }

    func testResizeUpdatesLastSize() throws {
        let mock = MockPTYProcess()
        try mock.start(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )
        mock.resize(PTYSize(cols: 120, rows: 40))
        XCTAssertEqual(mock.lastSize, PTYSize(cols: 120, rows: 40))
    }

    func testTerminateStopsProcessAndFiresHandler() throws {
        let mock = MockPTYProcess()
        try mock.start(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )

        let expectation = expectation(description: "termination handler fired")
        mock.terminationHandler = { code in
            XCTAssertEqual(code, 0)
            expectation.fulfill()
        }
        mock.terminate()

        wait(for: [expectation], timeout: 1)
        XCTAssertFalse(mock.isRunning)
        XCTAssertEqual(mock.terminateCallCount, 1)
    }

    func testSimulateCrashFiresTerminationHandlerWithNonZeroCode() throws {
        let mock = MockPTYProcess()
        try mock.start(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )

        let expectation = expectation(description: "crash handler fired")
        mock.terminationHandler = { code in
            XCTAssertEqual(code, 139)
            expectation.fulfill()
        }
        mock.simulateCrash(code: 139)

        wait(for: [expectation], timeout: 1)
        XCTAssertFalse(mock.isRunning)
        // A crash is not a caller-initiated terminate().
        XCTAssertEqual(mock.terminateCallCount, 0)
    }

    func testDoubleExitOnlyFiresHandlerOnce() throws {
        let mock = MockPTYProcess()
        try mock.start(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )

        var fireCount = 0
        mock.terminationHandler = { _ in fireCount += 1 }
        mock.terminate()
        mock.terminate() // second call after already stopped must be a no-op
        mock.simulateCrash()

        XCTAssertEqual(fireCount, 1)
    }

    func testOutputStreamDeliversSimulatedBytes() async throws {
        let mock = MockPTYProcess()
        try mock.start(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            initialSize: PTYSize(cols: 80, rows: 24)
        )

        async let collected: Data? = mock.outputStream.first(where: { _ in true })
        mock.simulateOutput("hello from mock")

        let awaited = await collected
        let result = try XCTUnwrap(awaited)
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "hello from mock")
    }
}

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
        for await chunk in process.outputStream {
            collected.append(chunk)
        }

        let printedEnvironment = String(decoding: collected, as: UTF8.self)
        XCTAssertTrue(printedEnvironment.contains("TERM=xterm-256color"))
        XCTAssertFalse(printedEnvironment.contains("TERM=dumb"))
        XCTAssertTrue(printedEnvironment.contains("COLORTERM=truecolor"))
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

    func testEmptyToolListNeverThrows() {
        let checker = StartupEnvironmentChecker(locator: FakeLocator(available: []))
        let report = checker.check(tools: [])
        XCTAssertTrue(report.foundTools.isEmpty)
        XCTAssertTrue(report.missingTools.isEmpty)
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
