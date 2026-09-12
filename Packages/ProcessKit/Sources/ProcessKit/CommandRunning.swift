import Foundation

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Seam between callers and the actual subprocess call — views/view models
/// never shell out directly; only implementations of this protocol do.
public protocol CommandRunning: Sendable {
    func run(_ arguments: [String], executable: URL, workingDirectory: URL) async throws -> CommandResult
    /// Runs with `environment` layered over the runner's own for this one
    /// call — how a single git command gets hooks the rest don't.
    func run(
        _ arguments: [String],
        executable: URL,
        workingDirectory: URL,
        environment: [String: String]
    ) async throws -> CommandResult
}

public extension CommandRunning {
    /// Runners with no environment of their own to extend run unchanged.
    func run(
        _ arguments: [String],
        executable: URL,
        workingDirectory: URL,
        environment: [String: String]
    ) async throws -> CommandResult {
        try await run(arguments, executable: executable, workingDirectory: workingDirectory)
    }
}

public struct ProcessCommandRunner: CommandRunning {
    private let timeout: TimeInterval
    private let environmentOverrides: [String: String]

    public init(timeout: TimeInterval = 60, environmentOverrides: [String: String] = [:]) {
        self.environmentOverrides = environmentOverrides
        self.timeout = timeout
    }

    public func run(_ arguments: [String], executable: URL, workingDirectory: URL) async throws -> CommandResult {
        try await execute(arguments, executable: executable, workingDirectory: workingDirectory, extraEnvironment: [:])
    }

    public func run(
        _ arguments: [String],
        executable: URL,
        workingDirectory: URL,
        environment: [String: String]
    ) async throws -> CommandResult {
        try await execute(arguments, executable: executable, workingDirectory: workingDirectory, extraEnvironment: environment)
    }

    private func execute(
        _ arguments: [String],
        executable: URL,
        workingDirectory: URL,
        extraEnvironment: [String: String]
    ) async throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardInput = nil
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        process.environment = ProcessInfo.processInfo.environment
            .merging(environmentOverrides) { _, override in override }
            .merging(extraEnvironment) { _, override in override }

        let outPipe = process.standardOutput as! Pipe
        let errPipe = process.standardError as! Pipe
        let outCollector = PipeCollector(handle: outPipe.fileHandleForReading)
        let errCollector = PipeCollector(handle: errPipe.fileHandleForReading)

        let state = ProcessRunnerState(
            process: process,
            outCollector: outCollector,
            errCollector: errCollector
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.continuation = continuation
                outCollector.start()
                errCollector.start()

                state.timeoutTask = Task {
                    try? await Task.sleep(for: .seconds(self.timeout))
                    guard !Task.isCancelled else { return }
                    state.terminateProcess()
                    state.complete(with: .failure(CommandTimeoutError(seconds: self.timeout)))
                }

                process.terminationHandler = { proc in
                    let outData = outCollector.finish()
                    let errData = errCollector.finish()
                    state.complete(with: .success(CommandResult(
                        exitCode: proc.terminationStatus,
                        stdout: String(decoding: outData, as: UTF8.self),
                        stderr: String(decoding: errData, as: UTF8.self)
                    )))
                }

                do {
                    try process.run()
                } catch {
                    state.terminateProcess()
                    state.complete(with: .failure(error))
                }
            }
        } onCancel: {
            state.terminateProcess()
            state.complete(with: .failure(CancellationError()))
        }
    }
}

/// A command exceeded its `ProcessCommandRunner` timeout and was terminated.
public struct CommandTimeoutError: Error, Equatable, LocalizedError {
    public let seconds: TimeInterval

    public var errorDescription: String? {
        "The command did not finish within \(Int(seconds))s and was cancelled."
    }
}

private final class ProcessRunnerState: @unchecked Sendable {
    private let lock = NSLock()
    let process: Process
    let outCollector: PipeCollector
    let errCollector: PipeCollector
    var continuation: CheckedContinuation<CommandResult, any Error>?
    var timeoutTask: Task<Void, Never>?
    private var isCompleted = false

    init(process: Process, outCollector: PipeCollector, errCollector: PipeCollector) {
        self.process = process
        self.outCollector = outCollector
        self.errCollector = errCollector
    }

    func complete(with result: Result<CommandResult, any Error>) {
        lock.lock()
        guard !isCompleted, let cont = continuation else {
            lock.unlock()
            return
        }
        isCompleted = true
        continuation = nil
        let task = timeoutTask
        timeoutTask = nil
        process.terminationHandler = nil
        lock.unlock()

        task?.cancel()

        switch result {
        case .success(let value):
            cont.resume(returning: value)
        case .failure(let error):
            cont.resume(throwing: error)
        }
    }

    func terminateProcess() {
        process.terminationHandler = nil
        outCollector.cancel()
        errCollector.cancel()
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            if pid > 0 {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                    if kill(pid, 0) == 0 {
                        kill(pid, SIGKILL)
                    }
                }
            }
        }
    }
}

/// Drains a pipe while the child is running. Waiting for termination before
/// reading can deadlock once a chatty `git diff` fills the kernel pipe buffer.
///
/// Only the `readabilityHandler` closure ever calls `handle.availableData` —
/// `finish()` used to do its own racing read from the termination-handler
/// thread, which could interleave with an in-flight `readabilityHandler`
/// read on the same fd. For output that fit in one pipe read that race was
/// harmless, but a large `git diff` (spanning multiple reads) could lose its
/// final chunk to the race, making that poll observe a truncated/empty diff
/// even though real changes existed — the Git Changes panel would flash
/// "No Changes" and then recover on the next poll. `finish()` now just waits
/// for the reader to observe EOF instead of reading itself.
///
/// The draining runs on our own user-interactive queue rather than on
/// `FileHandle.readabilityHandler`. `finish()` is called from the process
/// termination handler, which inherits the QoS of whoever launched the
/// command — user-interactive for anything driven by the UI — and it blocks
/// on `eofSemaphore`. Foundation's readability handler runs at default QoS,
/// so that wait was a textbook priority inversion, and Thread Performance
/// Checker logged a backtrace for every single git command the app ran.
/// Draining at the same QoS as the thread that waits on it removes the
/// inversion (and the log spam) instead of hiding it.
private final class PipeCollector: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var data = Data()
    private var isEOF = false
    private let eofSemaphore = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(
        label: "com.niclassslua.flotilla.processkit.pipe-collector",
        qos: .userInteractive
    )

    init(handle: FileHandle) {
        self.handle = handle
    }

    func start() {
        queue.async { [self] in
            // `availableData` blocks until the child writes or closes its end,
            // so this loop drains continuously — the pipe buffer never fills,
            // which is the deadlock the old readability handler also avoided.
            while true {
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    markEOF()
                    return
                }
                append(chunk)
            }
        }
    }

    func finish() -> Data {
        // The child has already exited by the time this is called, so its
        // end of the pipe is closed and the reader should observe EOF almost
        // immediately; the timeout is just a safety net.
        _ = eofSemaphore.wait(timeout: .now() + 5)
        lock.lock()
        let snapshot = data
        lock.unlock()
        return snapshot
    }

    private func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func cancel() {
        try? handle.close()
        markEOF()
    }

    private func markEOF() {
        lock.lock()
        let alreadySignaled = isEOF
        isEOF = true
        lock.unlock()
        guard !alreadySignaled else { return }
        eofSemaphore.signal()
    }
}

