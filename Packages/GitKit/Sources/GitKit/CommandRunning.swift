import Foundation

public struct CommandResult: Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Seam between GitService and the actual subprocess call — views/view
/// models never shell out directly; only implementations of this protocol do.
public protocol CommandRunning: Sendable {
    func run(_ arguments: [String], executable: URL, workingDirectory: URL) async throws -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ arguments: [String], executable: URL, workingDirectory: URL) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory

            let outPipe = Pipe()
            let errPipe = Pipe()
            let outCollector = PipeCollector(handle: outPipe.fileHandleForReading)
            let errCollector = PipeCollector(handle: errPipe.fileHandleForReading)
            process.standardOutput = outPipe
            process.standardError = errPipe
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
}

/// Drains a pipe while the child is running. Waiting for termination before
/// reading can deadlock once a chatty `git diff` fills the kernel pipe.
private final class PipeCollector: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var data = Data()
    private var hasFinished = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    func start() {
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.append(chunk)
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

        handle.readabilityHandler = nil
        append(handle.readDataToEndOfFile())
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
