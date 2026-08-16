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
}

public struct ProcessCommandRunner: CommandRunning {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 60) {
        self.timeout = timeout
    }

    public func run(_ arguments: [String], executable: URL, workingDirectory: URL) async throws -> CommandResult {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.standardInput = nil
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            // Prevent git from opening a terminal prompt for credentials etc.
            process.environment = [
                "GIT_TERMINAL_PROMPT": "0",
            ]

            let outPipe = process.standardOutput as! Pipe
            let errPipe = process.standardError as! Pipe
            let outCollector = PipeCollector(handle: outPipe.fileHandleForReading)
            let errCollector = PipeCollector(handle: errPipe.fileHandleForReading)
            outCollector.start()
            errCollector.start()

            process.terminationHandler = { proc in
                let outData = outCollector.finish()
                let errData = errCollector.finish()
                continuation.resume(returning: CommandResult(
                    exitCode: proc.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }

            do {
                try process.run()
            } catch {
                _ = outCollector.finish()
                _ = errCollector.finish()
                continuation.resume(throwing: error)
            }
        }
    }

    // Wall-clock timeout support: cancel the running process if the timeout
    // is exceeded. Called from the event handler when the process runs too long.
    /// Wall-clock timeout support: cancel the running process if the timeout
    // exceeds. Called from the event handler when the process runs too long.
    /// For compatibility with the `CommandRunning` protocol, this is a no-op
    // in the base implementation; concrete subclasses may override.
    func cancelIfTimedOut(process: Process, continuation: CheckedContinuation<CommandResult, Error>) {
        // Best-effort terminate; don't block.
        process.terminate()
        continuation.resume(throwing: NSError(domain: "ProcessKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Process exceeded \(self.timeout)s timeout"]))
    }
}

/// Drains a pipe while the child is running. Waiting for termination before
/// reading can deadlock once a chatty `git diff` fills the kernel pipe buffer.
private final class PipeCollector: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var data = Data()
    private var hasFinished = false
    /// True while the readability handler is between its `read` and its
    /// `append` — the window where bytes it has consumed are not yet visible
    /// to `finish()`. `finish()` waits for this to clear before snapshotting,
    /// so an in-flight handler read can never lose the bytes it consumed.
    private var handlerReadInFlight = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    func start() {
        handle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            self.lock.lock()
            self.handlerReadInFlight = true
            self.lock.unlock()
            let chunk = handle.availableData
            self.lock.lock()
            self.handlerReadInFlight = false
            self.lock.unlock()
            guard !chunk.isEmpty else { return }
            self.append(chunk)
        }
    }

    func finish() -> Data {
        lock.lock()
        guard !hasFinished else {
            let snapshot = data
            lock.unlock()
            return snapshot
        }
        hasFinished = true
        lock.unlock()

        // The termination handler can fire while the readability handler is
        // mid-read: that read has *consumed* bytes that are therefore not
        // visible to `availableData` below, and its append would land after
        // our snapshot — silently losing the child's tail output. Wait
        // (bounded) for any in-flight handler read to settle first; once
        // the child has exited the handler's read cannot block.
        for _ in 0..<200 {
            lock.lock()
            let inFlight = handlerReadInFlight
            lock.unlock()
            if !inFlight { break }
            Thread.sleep(forTimeInterval: 0.0001)
        }

        // Drain any remaining available data without blocking; if the underlying
        // file descriptor has been closed by the termination handler, readDataToEndOfFile
        // would block until all inheritors close their copy of the write end.
        handle.readabilityHandler = nil
        let available = handle.availableData
        if !available.isEmpty {
            append(available)
        }
        lock.lock()
        let snapshot = data
        lock.unlock()
        return snapshot
    }

    private func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }
}