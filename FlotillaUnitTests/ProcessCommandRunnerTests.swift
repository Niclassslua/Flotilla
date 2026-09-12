import XCTest
import ProcessKit

final class ProcessCommandRunnerTests: XCTestCase {
    func testDrainsLargeOutputWithoutPipeDeadlock() async throws {
        let result = try await ProcessCommandRunner().run(
            ["1", "100000"],
            executable: URL(fileURLWithPath: "/usr/bin/seq"),
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.hasPrefix("1\n2\n3\n"))
        XCTAssertTrue(result.stdout.hasSuffix("100000\n"))
        XCTAssertGreaterThan(result.stdout.utf8.count, 500_000)
    }

    func testInheritsParentEnvironmentForPathLookups() async throws {
        let result = try await ProcessCommandRunner().run(
            ["-c", "echo $HOME"],
            executable: URL(fileURLWithPath: "/bin/sh"),
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertFalse(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "HOME should be inherited from the parent process")
    }

    func testTimeoutCancelsHungProcessAndThrows() async throws {
        do {
            _ = try await ProcessCommandRunner(timeout: 0.2).run(
                ["100"],
                executable: URL(fileURLWithPath: "/bin/sleep"),
                workingDirectory: URL(fileURLWithPath: "/tmp")
            )
            XCTFail("expected a timeout error")
        } catch let error as CommandTimeoutError {
            XCTAssertEqual(error.seconds, 0.2)
        }
    }

    func testCollectsBothStreamsWhenTheyAreLargeAndSimultaneous() async throws {
        let result = try await ProcessCommandRunner().run(
            ["-c", "seq 1 40000 & seq 1 40000 >&2; wait"],
            executable: URL(fileURLWithPath: "/bin/sh"),
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.hasSuffix("40000\n"))
        XCTAssertTrue(result.stderr.hasSuffix("40000\n"))
    }

    func testNonZeroExitIsReturnedRatherThanThrown() async throws {
        let result = try await ProcessCommandRunner().run(
            ["-c", "echo out; echo bad >&2; exit 3"],
            executable: URL(fileURLWithPath: "/bin/sh"),
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stdout, "out\n")
        XCTAssertEqual(result.stderr, "bad\n")
    }

    func testLaunchFailureThrowsInsteadOfHanging() async throws {
        do {
            _ = try await ProcessCommandRunner().run(
                [],
                executable: URL(fileURLWithPath: "/definitely/not/an/executable"),
                workingDirectory: URL(fileURLWithPath: "/tmp")
            )
            XCTFail("expected a launch failure")
        } catch is CommandTimeoutError {
            XCTFail("a failed launch must not be reported as a timeout")
        } catch {
            // Any launch error is fine; the contract is that `run` returns.
        }
    }

    /// Git and GitHub callers disable credential prompts by supplying their
    /// own environment; the generic runner otherwise inherits the parent's.
    func testEnvironmentOverridesAreMergedOverTheInheritedEnvironment() async throws {
        let result = try await ProcessCommandRunner(environmentOverrides: ["GIT_TERMINAL_PROMPT": "0"]).run(
            ["-c", "echo \"$GIT_TERMINAL_PROMPT|${HOME:+has-home}\""],
            executable: URL(fileURLWithPath: "/bin/sh"),
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "0|has-home")
    }

    /// Timing out a *chatty* command used to close the read end of the pipe
    /// while the collector thread was blocked inside `availableData`, which
    /// raised `NSFileHandleOperationException` — an Objective-C exception
    /// that no Swift frame can catch, so the whole app died. The older
    /// timeout test above uses `sleep`, which writes nothing and therefore
    /// never has a read in flight when the timeout fires. If this regresses,
    /// the test process aborts rather than failing an assertion; that is the
    /// only observable form the defect has.
    func testTimingOutCommandsThatAreStillWritingDoesNotCrash() async throws {
        await withTaskGroup(of: (any Error)?.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    do {
                        _ = try await ProcessCommandRunner(timeout: 0.05).run(
                            ["-c", "yes chatty-output | head -400000"],
                            executable: URL(fileURLWithPath: "/bin/sh"),
                            workingDirectory: URL(fileURLWithPath: "/tmp")
                        )
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            for await error in group {
                if let error, !(error is CommandTimeoutError) {
                    XCTFail("expected a timeout or a completed run, got \(error)")
                }
            }
        }
    }

    /// Cancelling a chatty command mid-stream closes the same descriptor from
    /// the cancellation handler, so it hits the same race as the timeout path.
    func testCancellingCommandsThatAreStillWritingDoesNotCrash() async throws {
        for _ in 0..<20 {
            let task = Task {
                try await ProcessCommandRunner(timeout: 10).run(
                    ["-c", "yes chatty-output | head -400000"],
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    workingDirectory: URL(fileURLWithPath: "/tmp")
                )
            }
            try await Task.sleep(for: .milliseconds(5))
            task.cancel()
            do {
                _ = try await task.value
            } catch is CancellationError {
                // Success
            } catch {
                XCTFail("expected CancellationError, got \(error)")
            }
        }
    }

    /// A task cancelled before the runner's body executes must not launch the
    /// command at all: the cancellation used to be dropped, so the command ran
    /// to completion and resumed with a successful but empty result.
    func testCancellationBeforeLaunchNeitherRunsTheCommandNorReportsSuccess() async throws {
        let marker = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flotilla-precancel-\(UUID().uuidString)")
        let task = Task {
            try await ProcessCommandRunner(timeout: 10).run(
                ["-c", "touch \(marker.path)"],
                executable: URL(fileURLWithPath: "/bin/sh"),
                workingDirectory: URL(fileURLWithPath: "/tmp")
            )
        }
        task.cancel()

        do {
            let result = try await task.value
            XCTFail("expected cancellation, got exit \(result.exitCode)")
        } catch is CancellationError {
            // Success
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "a cancelled run must not have launched the command"
        )
    }

    func testCallerCancellationTerminatesProcessAndThrowsCancellationError() async throws {
        let task = Task {
            try await ProcessCommandRunner(timeout: 10.0).run(
                ["10"],
                executable: URL(fileURLWithPath: "/bin/sleep"),
                workingDirectory: URL(fileURLWithPath: "/tmp")
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation error")
        } catch is CancellationError {
            // Success
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }
}
