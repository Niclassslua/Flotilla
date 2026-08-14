import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Real PTY-backed process using BSD `openpty(3)` to allocate the
/// master/slave pair and Foundation's `Process` to fork+exec onto the slave.
/// `Process.terminationHandler` and `FileHandle.readabilityHandler` invoke
/// on Foundation-managed queues. Mutable process/fd state is protected by a
/// lock so terminal input, resizing, and child termination cannot race.
public final class SystemPTYProcess: PTYProcessProtocol, @unchecked Sendable {
    public let id = UUID()
    private let stateLock = NSLock()
    private var storedTerminationHandler: ((Int32) -> Void)?
    private var running = false

    public var terminationHandler: ((Int32) -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return storedTerminationHandler
        }
        set {
            stateLock.lock()
            storedTerminationHandler = newValue
            stateLock.unlock()
        }
    }

    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private let broadcaster = OutputBroadcaster()

    /// Computed, not stored: each access hands back a fresh subscription
    /// so multiple independent consumers (terminal view, hooks observer)
    /// each see every chunk. See `OutputBroadcaster`.
    public var outputStream: AsyncStream<Data> { broadcaster.subscribe() }

    private var process: Process?
    private var masterFD: Int32 = -1
    private var masterFileHandle: FileHandle?

    public init() {}

    public func start(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        initialSize: PTYSize
    ) throws {
        stateLock.lock()
        guard !running else {
            stateLock.unlock()
            throw PTYProcessError.alreadyRunning
        }
        running = true
        stateLock.unlock()

        var master: Int32 = -1
        var slave: Int32 = -1
        var winSize = winsize(
            ws_row: UInt16(initialSize.rows),
            ws_col: UInt16(initialSize.cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard openpty(&master, &slave, nil, nil, &winSize) == 0 else {
            stateLock.lock()
            running = false
            stateLock.unlock()
            throw PTYProcessError.failedToOpenPTY
        }
        stateLock.lock()
        masterFD = master
        stateLock.unlock()

        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.stateLock.lock()
            self.running = false
            let handle = self.masterFileHandle
            self.masterFileHandle = nil
            let fd = self.masterFD
            self.masterFD = -1
            let callback = self.storedTerminationHandler
            self.stateLock.unlock()

            handle?.readabilityHandler = nil
            if fd >= 0 { close(fd) }
            self.broadcaster.finish()
            callback?(proc.terminationStatus)
        }

        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: false)
        masterHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.broadcaster.broadcast(data)
        }
        stateLock.lock()
        self.process = process
        masterFileHandle = masterHandle
        stateLock.unlock()

        do {
            try process.run()
        } catch {
            masterHandle.readabilityHandler = nil
            close(master)
            close(slave)
            stateLock.lock()
            running = false
            masterFD = -1
            self.process = nil
            masterFileHandle = nil
            stateLock.unlock()
            throw error
        }
        close(slave) // parent no longer needs its copy once the child owns one
    }

    public func send(input: Data) {
        stateLock.lock()
        let fd = running ? masterFD : -1
        stateLock.unlock()
        guard fd >= 0 else { return }
        input.withUnsafeBytes { raw in
            _ = write(fd, raw.baseAddress, raw.count)
        }
    }

    public func resize(_ size: PTYSize) {
        stateLock.lock()
        let fd = masterFD
        stateLock.unlock()
        guard fd >= 0 else { return }
        var ws = winsize(
            ws_row: UInt16(size.rows),
            ws_col: UInt16(size.cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(fd, TIOCSWINSZ, &ws)
    }

    public func terminate() {
        stateLock.lock()
        let process = process
        stateLock.unlock()
        process?.terminate()
    }
}
