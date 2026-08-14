import Foundation

/// Pure-Swift stand-in for `PTYProcessProtocol` used across unit tests and
/// UI tests (`UI_TESTING=1`). Scripted via `simulateOutput`/`simulateCrash`
/// rather than touching any real subprocess or PTY.
/// `@unchecked Sendable` to match `PTYProcessProtocol`'s real implementation
/// and let tests pass mocks across `async`/`await` boundaries. No internal
/// locking — tests are expected to drive one instance from one task.
public final class MockPTYProcess: PTYProcessProtocol, @unchecked Sendable {
    public let id = UUID()
    public var terminationHandler: ((Int32) -> Void)?
    public private(set) var isRunning = false

    public private(set) var startedExecutable: URL?
    public private(set) var startedArguments: [String] = []
    public private(set) var startedEnvironment: [String: String] = [:]
    public private(set) var startedWorkingDirectory: URL?
    public private(set) var sentInput: [Data] = []
    public private(set) var lastSize: PTYSize?
    public private(set) var startCallCount = 0
    public private(set) var terminateCallCount = 0

    /// When true, `start` throws `.failedToOpenPTY` instead of succeeding.
    public var shouldFailToStart = false

    /// When true, `send(input:)` immediately feeds the same bytes back
    /// through `outputStream`, simulating a shell echoing keystrokes. Off
    /// by default so existing input-recording tests stay purely passive;
    /// the UI-test composition root turns it on to make terminals interactive
    /// without launching third-party agent binaries during automation.
    public var echoInputToOutput = false

    private let broadcaster = OutputBroadcaster()

    /// Computed, not stored: each access hands back a fresh subscription
    /// so multiple independent consumers (terminal view, hooks observer)
    /// each see every chunk. See `OutputBroadcaster`.
    public var outputStream: AsyncStream<Data> { broadcaster.subscribe() }

    public init() {}

    public func start(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        initialSize: PTYSize
    ) throws {
        startCallCount += 1
        if shouldFailToStart {
            throw PTYProcessError.failedToOpenPTY
        }
        guard !isRunning else { throw PTYProcessError.alreadyRunning }

        startedExecutable = executable
        startedArguments = arguments
        startedEnvironment = environment
        startedWorkingDirectory = workingDirectory
        lastSize = initialSize
        isRunning = true
    }

    public func send(input: Data) {
        sentInput.append(input)
        if echoInputToOutput {
            broadcaster.broadcast(input)
        }
    }

    public func resize(_ size: PTYSize) {
        lastSize = size
    }

    public func terminate() {
        terminateCallCount += 1
        simulateExit(code: 0)
    }

    /// Test hook: push bytes onto the output stream as if the child wrote them.
    public func simulateOutput(_ string: String) {
        broadcaster.broadcast(Data(string.utf8))
    }

    /// Test hook: simulate the child process dying unexpectedly.
    public func simulateCrash(code: Int32 = -1) {
        simulateExit(code: code)
    }

    private func simulateExit(code: Int32) {
        guard isRunning else { return }
        isRunning = false
        broadcaster.finish()
        terminationHandler?(code)
    }
}
