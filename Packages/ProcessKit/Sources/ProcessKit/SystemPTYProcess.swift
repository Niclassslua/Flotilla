import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Real PTY-backed process using `forkpty(3)`, which allocates the pty
/// pair, forks, and — via its internal `login_tty(3)` — makes the child a
/// fresh session leader whose controlling terminal is the pty slave. That
/// specific arrangement matters: only a session leader with no controlling
/// terminal yet, at the moment it opens the tty, becomes that pty's
/// controlling-terminal owner and thus a valid `SIGWINCH` recipient on
/// resize. Foundation's `Process` (a thin `posix_spawn` wrapper, with no
/// fork-time hook and no session-leader control) can't produce that.
///
/// All argv/envp/path C strings are built *before* `forkpty`, so the
/// child's code between fork and exec touches only raw libc calls
/// (`chdir`, `execve`, `_exit`) — no Swift/ObjC runtime allocation, which is
/// what makes calling `fork` here safe. This mirrors the pattern SwiftTerm
/// itself uses (`PseudoTerminalHelpers.fork`, already vendored in this repo
/// via TerminalKit) for the same reason.
///
/// Output is read via a `DispatchSourceRead` rather than
/// `FileHandle.readabilityHandler`. The dispatch source's cancel handler
/// owns the `close(fd)` call, which guarantees the fd is never closed while
/// an in-flight read event is executing — eliminating the race that causes
/// `NSFileHandleOperationException: availableData: Bad file descriptor`.
/// Child exit is observed via a blocking `waitpid` on a background queue.
/// Mutable process/fd state is protected by a lock so terminal input,
/// resizing, and child termination cannot race.
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

    private var storedLastResizeAt: Date?
    private var storedLastInputAt: Date?

    public var lastResizeAt: Date? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedLastResizeAt
    }

    public var lastInputAt: Date? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedLastInputAt
    }

    private let broadcaster = OutputBroadcaster()

    /// Computed, not stored: each access hands back a fresh subscription
    /// so multiple independent consumers (terminal view, hooks observer)
    /// each see every chunk. See `OutputBroadcaster`.
    public var outputStream: AsyncStream<Data> { broadcaster.subscribe() }

    private var childPID: pid_t = -1
    private var masterFD: Int32 = -1
    private var masterReadSource: DispatchSourceRead?

    public init() {}

    deinit {
        masterReadSource?.cancel()
    }

    // Prevent libdispatch trap: source must be cancelled before deallocation.
    // The cancel handler closes masterFD; we keep the process entry in the
    // manager until exit is observed (see SessionProcessManager.terminate).

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

        // Build every C string/array the child could need *before* forking
        // — as raw allocated buffers, not Swift Arrays passed via `&`, so
        // the forked child (one thread, no Swift runtime guarantees) never
        // touches anything but these already-materialized raw pointers and
        // plain libc calls.
        guard let cExecutable = strdup(executable.path) else {
            stateLock.lock()
            running = false
            stateLock.unlock()
            throw PTYProcessError.failedToOpenPTY
        }
        let cArgv = Self.allocateCStringArray([executable.path] + arguments)
        let cEnvp = Self.allocateCStringArray(environment.map { "\($0.key)=\($0.value)" })
        let cWorkingDirectory = strdup(workingDirectory.path)
        defer {
            free(cExecutable)
            Self.freeCStringArray(cArgv)
            Self.freeCStringArray(cEnvp)
            free(cWorkingDirectory)
        }

        var master: Int32 = -1
        var winSize = winsize(
            ws_row: UInt16(initialSize.rows),
            ws_col: UInt16(initialSize.cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        let pid = forkpty(&master, nil, nil, &winSize)
        guard pid >= 0 else {
            stateLock.lock()
            running = false
            stateLock.unlock()
            throw PTYProcessError.failedToOpenPTY
        }

        if pid == 0 {
            // Child. `forkpty` already made us the session leader with the
            // pty slave as our controlling terminal (via `login_tty`).
            if let cWorkingDirectory {
                _ = chdir(cWorkingDirectory)
            }
            _ = execve(cExecutable, cArgv, cEnvp)
            _exit(127) // execve only returns on failure.
        }

        // Use DispatchSourceRead so the cancel handler owns close(master).
        // This is the only safe pattern: GCD guarantees that once cancel()
        // is called no new event handler invocations are queued, and the
        // cancel handler runs only after any already-running event handler
        // returns — so the fd is never closed while a read is in progress.
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(master, &buffer, buffer.count)
            if n <= 0, let self {
                // Master is permanently readable after child exit — cancel source
                // to stop the source from re-firing continuously at utility QoS.
                source.cancel()
                return
            }
            guard n > 0, let self else { return }
            self.broadcaster.broadcast(Data(buffer[..<n]))
        }
        source.setCancelHandler {
            Darwin.close(master)
        }
        source.resume()

        stateLock.lock()
        childPID = pid
        masterFD = master
        masterReadSource = source
        stateLock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            // WIFEXITED/WEXITSTATUS/WTERMSIG, reimplemented: these are C
            // macros and don't import into Swift.
            let exitCode: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : status & 0x7f
            self?.handleChildExit(exitCode)
        }
    }

    private func handleChildExit(_ exitCode: Int32) {
        stateLock.lock()
        running = false
        let source = masterReadSource
        masterReadSource = nil
        masterFD = -1
        childPID = -1
        let callback = storedTerminationHandler
        stateLock.unlock()

        // cancel() stops new event handler invocations from being queued and,
        // once any in-flight invocation returns, runs the cancel handler
        // (which closes the fd). This is the correct teardown order.
        source?.cancel()
        broadcaster.finish()
        callback?(exitCode)
    }

    /// Null-terminated `argv`/`envp`-style C string array, matching the
    /// pattern SwiftTerm's own `PseudoTerminalHelpers` uses around
    /// `forkpty` — raw allocated pointers, not a Swift Array bridged via
    /// `&`, so nothing about the fork-to-exec window depends on Array's
    /// copy-on-write machinery.
    private static func allocateCStringArray(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let base = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() {
            base[index] = strdup(string)
        }
        base[strings.count] = nil
        return base
    }

    private static func freeCStringArray(_ array: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) {
        var index = 0
        while let pointer = array[index] {
            free(pointer)
            index += 1
        }
        array.deallocate()
    }

    public func send(input: Data) {
        // Write on a background queue so the main thread never blocks.
        DispatchQueue.global(qos: .utility).async {
            let fd: Int32
            self.stateLock.lock()
            fd = self.masterFD
            self.stateLock.unlock()
            guard fd >= 0 else { return }
            input.withUnsafeBytes { raw in
                // Retry until all bytes are written (or EINTR/EAGAIN).
                let count = raw.count
                var wrote = 0
                while wrote < count {
                    let n = write(fd, raw.baseAddress! + wrote, count - wrote)
                    if n < 0 {
                        if errno == EINTR { continue }
                        if errno == EAGAIN { usleep(1000); continue }
                        break
                    }
                    wrote += n
                }
            }
        }
    }

    public func resize(_ size: PTYSize) {
        stateLock.lock()
        let fd = masterFD
        guard fd >= 0 else { stateLock.unlock(); return }
        // Validate rows/cols to avoid UInt16 trap on out-of-range values.
        let rows = min(max(Int(size.rows), 0), 65535)
        let cols = min(max(Int(size.cols), 0), 65535)
        var ws = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        stateLock.unlock()
        _ = ioctl(fd, TIOCSWINSZ, &ws)
    }

    public func terminate() {
        stateLock.lock()
        let pid = childPID
        stateLock.unlock()
        guard pid > 0 else { return }

        // Send SIGTERM to the process group so descendants are also signaled.
        killpg(pid, SIGTERM)

        // Escalate to SIGKILL after ~3 seconds if the process hasn't exited.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            let updatedPID = pid
            // Use WNOHANG so this doesn't block if the process is still running.
            var status: Int32 = 0
            while waitpid(updatedPID, &status, WNOHANG) == -1 && errno == EINTR {}
            // Check if process has exited: low 7 bits signalled, or process exited.
            let exited = (status & 0x7f) != 0 || status >> 8 != 0
            if exited {
                // Process already terminated — nothing to do.
                return
            }
            // Process still running after escalation timeout — send SIGKILL.
            killpg(updatedPID, SIGKILL)
        }
    }
}
