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
}
