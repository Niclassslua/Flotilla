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
/// child's code between fork and exec touches only scalar control flow and
/// raw libc calls (`sigprocmask`, `signal`, `chdir`, `execve`, `_exit`) — no
/// Swift/ObjC runtime allocation, which is
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
    private let outputQueue = DispatchQueue(label: "com.niclassslua.flotilla.pty.output", qos: .userInitiated)
    private let inputQueue = DispatchQueue(label: "com.niclassslua.flotilla.pty.input", qos: .userInitiated)

    /// Computed, not stored: each access hands back a fresh subscription
    /// so multiple independent consumers (terminal view, hooks observer)
    /// each see every chunk. See `OutputBroadcaster`.
    public var outputStream: AsyncStream<Data> { broadcaster.subscribe() }

    private var childPID: pid_t = -1
    private var masterFD: Int32 = -1
    private var masterReadSource: DispatchSourceRead?

    /// Ceiling on the post-exit drain in `handleChildExit`, so a pty that keeps
    /// producing (a surviving descendant still holds the slave) cannot stop the
    /// teardown that follows it.
    private static let maximumDrainBytes = 4 * 1_024 * 1_024
    private static let maximumDrainReads = 4_096

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
        // The child closes every descriptor above stdio before exec. Swift,
        // Network and Metal open plenty without close-on-exec, and a leaked
        // one outlives Flotilla inside a long-lived tmux server — a leaked
        // `flock` there locks every later Flotilla out of the companion
        // socket. Computed here because `sysconf` isn't async-signal-safe.
        let openMax = sysconf(_SC_OPEN_MAX)
        let descriptorLimit = Int32(clamping: openMax > 0 ? min(openMax, 65_536) : 10_240)

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
            //
            // Restore an empty signal mask and reset all signal dispositions
            // to SIG_DFL so the child does not inherit blocked signals (e.g.
            // SIGWINCH blocked on GCD / Swift concurrency threads) or ignored
            // dispositions across execve.
            var emptyMask = sigset_t()
            sigemptyset(&emptyMask)
            sigprocmask(SIG_SETMASK, &emptyMask, nil)

            // Deliberately use a scalar while loop here. Iterating a Swift
            // Range may instantiate generic metadata after fork, which can
            // deadlock or trap on a runtime lock held by another parent thread.
            var signalNumber: Int32 = 1
            while signalNumber < NSIG {
                _ = signal(signalNumber, SIG_DFL)
                signalNumber += 1
            }

            if let cWorkingDirectory {
                _ = chdir(cWorkingDirectory)
            }
            var descriptor: Int32 = STDERR_FILENO + 1
            while descriptor < descriptorLimit {
                _ = close(descriptor)
                descriptor += 1
            }
            _ = execve(cExecutable, cArgv, cEnvp)
            _exit(127) // execve only returns on failure.
        }

        // Use DispatchSourceRead so the cancel handler owns close(master).
        // This is the only safe pattern: GCD guarantees that once cancel()
        // is called no new event handler invocations are queued, and the
        // cancel handler runs only after any already-running event handler
        // returns — so the fd is never closed while a read is in progress.
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: outputQueue)
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(master, &buffer, buffer.count)
            if n <= 0 {
                // Master is permanently readable after child exit — cancel source
                // to stop the source from re-firing continuously at utility QoS.
                source.cancel()
                return
            }
            guard n > 0, let this = self else { return }
            this.broadcaster.broadcast(Data(buffer[..<n]))
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
            guard let self else { return }
            self.outputQueue.async {
                self.handleChildExit(exitCode)
            }
        }
    }

    private func handleChildExit(_ exitCode: Int32) {
        stateLock.lock()
        running = false
        let source = masterReadSource
        let fd = masterFD
        masterReadSource = nil
        masterFD = -1
        childPID = -1
        let callback = storedTerminationHandler
        stateLock.unlock()

        // A fast-exiting child (e.g. `/bin/echo`) can make `waitpid` return
        // before the read source's event handler has ever fired. Cancelling
        // the source then permanently discards the pending read — the child's
        // final output is lost and its stream ends empty. Drain whatever the
        // child wrote before tearing the source down. (An in-flight read event
        // consumes distinct bytes, so concurrent reads cannot duplicate
        // delivery.)
        //
        // `forkpty` hands back a *blocking* master, and reads on it only
        // return EIO once nothing holds the slave open. The exited child's own
        // surviving descendants still do, so a blocking drain here could park
        // this thread forever — and with it `broadcaster.finish()` and the
        // termination callback below, leaving the session displayed as running
        // for the rest of the app's life. Switch to non-blocking first so the
        // loop ends at EAGAIN, and bound it regardless.
        if fd >= 0 {
            let previousFlags = fcntl(fd, F_GETFL, 0)
            if previousFlags >= 0 {
                _ = fcntl(fd, F_SETFL, previousFlags | O_NONBLOCK)
            }
            var buffer = [UInt8](repeating: 0, count: 65536)
            var drained = 0
            // Bounded on reads as well as bytes: `drained` does not advance on
            // an `EINTR` retry, so a byte budget alone would not terminate the
            // loop if the signal kept arriving.
            var reads = 0
            while drained < Self.maximumDrainBytes, reads < Self.maximumDrainReads {
                reads += 1
                let n = Darwin.read(fd, &buffer, buffer.count)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { break }
                drained += n
                broadcaster.broadcast(Data(buffer[..<n]))
            }
        }

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

    /// Runs `body` on a private duplicate of the pty master, or returns `nil`
    /// when the process is no longer running.
    ///
    /// Reading `masterFD` under the lock and then using it after unlocking is
    /// a use-after-close waiting to happen: `handleChildExit` can close the
    /// descriptor in that window, and the number is then immediately available
    /// for reuse by any `open` anywhere in the process. A `write` that lands
    /// after such a reuse delivers the user's keystrokes into an unrelated
    /// file — plausibly the session database, which this app writes to
    /// constantly.
    ///
    /// `dup` under the lock removes the window without holding the lock across
    /// the syscall, which matters because a write to a pty whose reader has
    /// stopped can block indefinitely and must not stall `resize` or child
    /// teardown behind it.
    private func withDuplicatedMaster<T>(_ body: (Int32) -> T) -> T? {
        stateLock.lock()
        let fd = masterFD
        guard fd >= 0 else {
            stateLock.unlock()
            return nil
        }
        let duplicate = dup(fd)
        stateLock.unlock()
        guard duplicate >= 0 else { return nil }
        defer { close(duplicate) }
        return body(duplicate)
    }

    public func send(input: Data) {
        stateLock.lock()
        storedLastInputAt = Date()
        stateLock.unlock()

        // Write on a dedicated serial queue so writes are ordered and never block.
        inputQueue.async { [weak self] in
            guard let self else { return }
            _ = self.withDuplicatedMaster { fd in
                input.withUnsafeBytes { raw in
                    // Retry until all bytes are written (or EINTR/EAGAIN).
                    let count = raw.count
                    var wrote = 0
                    var stalls = 0
                    while wrote < count {
                        let n = write(fd, raw.baseAddress! + wrote, count - wrote)
                        if n < 0 {
                            if errno == EINTR { continue }
                            if errno == EAGAIN {
                                // Only reachable if the descriptor is in
                                // non-blocking mode; bounded at ~1s so a pty
                                // nobody is draining abandons the write instead
                                // of retrying forever.
                                stalls += 1
                                guard stalls < 1_000 else { break }
                                usleep(1000)
                                continue
                            }
                            break
                        }
                        wrote += n
                    }
                }
            }
        }
    }

    public func resize(_ size: PTYSize) {
        // Validate rows/cols to avoid UInt16 trap on out-of-range values.
        let rows = min(max(Int(size.rows), 0), 65535)
        let cols = min(max(Int(size.cols), 0), 65535)
        var ws = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        let applied = withDuplicatedMaster { fd in
            ioctl(fd, TIOCSWINSZ, &ws) == 0
        }
        guard applied == true else { return }
        stateLock.lock()
        storedLastResizeAt = Date()
        stateLock.unlock()
    }

    public func terminate() {
        stateLock.lock()
        let pid = childPID
        stateLock.unlock()
        guard pid > 0 else { return }

        // Send SIGTERM to the process group so descendants are also signaled.
        killpg(pid, SIGTERM)

        // Escalate to SIGKILL after ~3 seconds if the process hasn't exited.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let stillRunning = self.running && self.childPID == pid
            self.stateLock.unlock()
            guard stillRunning else { return }

            // Process still running after escalation timeout — send SIGKILL.
            killpg(pid, SIGKILL)
        }
    }
}
