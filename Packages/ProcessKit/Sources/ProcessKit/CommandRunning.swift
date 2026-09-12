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
                // Already cancelled before the body ran: nothing to launch.
                guard state.attach(continuation) else { return }

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
    var timeoutTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<CommandResult, any Error>?
    /// A result that arrived before the continuation existed — `onCancel`
    /// runs immediately when the surrounding task is already cancelled, which
    /// can beat the operation body. Without this, that cancellation was
    /// dropped and the command ran to completion anyway, resuming with an
    /// empty result because its collectors had already been cancelled.
    private var pendingResult: Result<CommandResult, any Error>?
    private var isCompleted = false

    init(process: Process, outCollector: PipeCollector, errCollector: PipeCollector) {
        self.process = process
        self.outCollector = outCollector
        self.errCollector = errCollector
    }

    /// Hands the continuation over. Returns `false` — after resuming it with
    /// the result that already settled — when there is nothing left to launch.
    func attach(_ continuation: CheckedContinuation<CommandResult, any Error>) -> Bool {
        lock.lock()
        if let pending = pendingResult {
            pendingResult = nil
            lock.unlock()
            resume(continuation, with: pending)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func complete(with result: Result<CommandResult, any Error>) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        guard let cont = continuation else {
            // Settled before `attach`; the continuation resumes with this.
            isCompleted = true
            pendingResult = result
            let task = timeoutTask
            timeoutTask = nil
            process.terminationHandler = nil
            lock.unlock()
            task?.cancel()
            return
        }
        isCompleted = true
        continuation = nil
        let task = timeoutTask
        timeoutTask = nil
        process.terminationHandler = nil
        lock.unlock()

        task?.cancel()
        resume(cont, with: result)
    }

    private func resume(
        _ continuation: CheckedContinuation<CommandResult, any Error>,
        with result: Result<CommandResult, any Error>
    ) {
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
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
/// Reading is driven by a `DispatchSourceRead` on our own user-interactive
/// queue, and the read end is closed **only** from the source's cancel
/// handler. That ordering is the whole point: GCD guarantees the cancel
/// handler runs after the last event handler has returned, so no read can
/// ever be in flight while the descriptor is being closed.
///
/// The previous version drained with a blocking `handle.availableData` loop
/// and let `cancel()` close the same descriptor from another thread — the
/// timeout task, the task-cancellation handler, and the failed-`run()` path
/// all do that. Closing an fd out from under a blocked `read(2)` makes
/// `availableData` fail with `EBADF`, and `FileHandle` reports an errno it
/// has no case for by raising `NSFileHandleOperationException`
/// ("*** -[NSConcreteFileHandle availableData]: unknown error"), which is an
/// Objective-C exception no Swift frame can catch — so every timed-out or
/// cancelled command was a coin flip on crashing the app. The same race also
/// risked reading from an unrelated fd that had reused the number.
///
/// Reads go through `read(2)` rather than `availableData` for the same
/// reason: a descriptor error must come back as an errno we handle, never as
/// an exception. The fd is put in non-blocking mode so the event handler
/// drains what is buffered and returns instead of parking the queue.
///
/// The queue is user-interactive because `finish()` blocks on `eofSemaphore`
/// from the process termination handler, which inherits the QoS of whoever
/// launched the command — user-interactive for anything driven by the UI.
/// Draining at the same QoS as the thread that waits on it removes the
/// priority inversion (and the Thread Performance Checker backtrace it
/// logged for every git command) instead of hiding it.
private final class PipeCollector: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var data = Data()
    private var isEOF = false
    private var didCancel = false
    private var didStart = false
    private var source: DispatchSourceRead?
    private let eofSemaphore = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(
        label: "com.niclassslua.flotilla.processkit.pipe-collector",
        qos: .userInteractive
    )

    init(handle: FileHandle) {
        self.handle = handle
    }

    func start() {
        lock.lock()
        // `onCancel` can fire before the operation body runs, so a collector
        // can already be cancelled by the time it would have started.
        guard !didCancel, !didStart else {
            lock.unlock()
            return
        }
        didStart = true
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        if flags != -1 {
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        self.source = source
        lock.unlock()

        source.setEventHandler { [self] in
            drain(descriptor: descriptor, source: source)
        }
        source.setCancelHandler { [self] in
            // The only place the read end is closed. Nothing is reading it
            // here: GCD runs this after the final event handler returns.
            try? handle.close()
            markEOF()
            lock.lock()
            self.source = nil
            lock.unlock()
        }
        source.activate()
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

    func cancel() {
        lock.lock()
        didCancel = true
        let source = self.source
        lock.unlock()

        guard let source else {
            // Either never started or already finished — no reader exists, so
            // closing here is safe (and a no-op if the handle is closed).
            try? handle.close()
            markEOF()
            return
        }
        // Asynchronous by design: the cancel handler does the closing once
        // the queue is clear of reads.
        source.cancel()
    }

    private func drain(descriptor: Int32, source: DispatchSourceRead) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress, raw.count)
            }
            if count > 0 {
                append(Data(buffer[0..<count]))
                continue
            }
            if count == 0 {
                // The child closed its end: EOF, and `finish()` can proceed.
                source.cancel()
                return
            }
            switch errno {
            case EINTR:
                continue
            case EAGAIN:
                // Everything buffered is drained; wait for the next event.
                return
            default:
                // EBADF and friends: stop reading rather than spin or throw.
                source.cancel()
                return
            }
        }
    }

    private func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
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
