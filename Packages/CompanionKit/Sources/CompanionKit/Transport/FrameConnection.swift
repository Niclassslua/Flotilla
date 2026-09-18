import Foundation
import Network

public enum TransportError: Error, Hashable, Sendable {
    /// The connection couldn't be established (refused, no route, DNS failure).
    case unreachable(String)
    case timedOut
    case closed
    case frameTooLarge(Int)
    case backpressure
    /// Local Network access was denied on the phone.
    case localNetworkDenied
}

/// A length-prefixed frame stream over one `NWConnection`.
///
/// Every frame is a `UInt32` big-endian length followed by that many bytes.
/// Sends are serialized on the connection's queue in call order, which the
/// secure channel's counters rely on.
public final class FrameConnection: @unchecked Sendable {
    public static let maximumFrameSize = 8 * 1024 * 1024

    public let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var isReady = false
    private var isCancelled = false
    private var stateHandlers: [@Sendable (NWConnection.State) -> Void] = []
    private var queuedBytes = 0
    private let maximumQueuedBytes = 16 * 1024 * 1024

    public var isConnected: Bool {
        lock.withLock { isReady && !isCancelled }
    }

    public init(connection: NWConnection, label: String = "companion.connection") {
        self.connection = connection
        self.queue = DispatchQueue(label: label)
    }

    public convenience init(endpoint: NWEndpoint) {
        let options = NWProtocolTCP.Options()
        options.connectionTimeout = 6
        options.enableKeepalive = true
        options.keepaliveIdle = 15
        let parameters = NWParameters(tls: nil, tcp: options)
        parameters.includePeerToPeer = false
        self.init(connection: NWConnection(to: endpoint, using: parameters))
    }

    /// Observes state changes after `start`, for detecting a dropped link.
    public func onStateChange(_ handler: @escaping @Sendable (NWConnection.State) -> Void) {
        lock.withLock {
            guard !isCancelled else { return }
            stateHandlers.append(handler)
        }
    }

    /// Starts the connection and waits until it is ready.
    public func start(timeout: Duration = .seconds(6)) async throws {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        self.lock.withLock { self.readyContinuation = continuation }
                        self.connection.start(queue: self.queue)
                    }
                } onCancel: {
                    self.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TransportError.timedOut
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func handle(_ state: NWConnection.State) {
        let (continuation, handlers): (CheckedContinuation<Void, Error>?, [@Sendable (NWConnection.State) -> Void]) = lock.withLock {
            if isCancelled { return (nil, []) }
            var toResume: CheckedContinuation<Void, Error>?
            switch state {
            case .ready:
                isReady = true
                toResume = readyContinuation
            case .failed, .cancelled, .waiting:
                if !isReady { toResume = readyContinuation }
                if case .cancelled = state {
                    isCancelled = true
                    isReady = false
                }
            default:
                break
            }
            if toResume != nil { readyContinuation = nil }
            return (toResume, stateHandlers)
        }
        switch state {
        case .ready:
            continuation?.resume()
        case .failed(let error):
            continuation?.resume(throwing: Self.map(error))
        case .waiting(let error):
            // `.waiting` means no path right now; for a direct connection that
            // is as good as unreachable, so fail fast and let another
            // candidate win.
            continuation?.resume(throwing: Self.map(error))
        case .cancelled:
            continuation?.resume(throwing: TransportError.closed)
        default:
            break
        }
        handlers.forEach { $0(state) }
    }

    static func map(_ error: NWError) -> TransportError {
        if case .dns(let code) = error, code == -65570 {
            return .localNetworkDenied
        }
        return .unreachable(error.debugDescription)
    }

    public func send(_ frame: Data) async throws {
        guard frame.count <= Self.maximumFrameSize else { throw TransportError.frameTooLarge(frame.count) }
        let packet = Self.lengthPrefix(frame.count) + frame
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: Self.map(error))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Enqueues a frame without waiting for it to be written. Enqueue order is
    /// preserved, which lets a caller seal and enqueue atomically.
    @discardableResult
    public func enqueue(_ frame: Data) -> Bool {
        let packet = Self.lengthPrefix(frame.count) + frame
        guard lock.withLock({
            guard queuedBytes + packet.count <= maximumQueuedBytes else { return false }
            queuedBytes += packet.count
            return true
        }) else { return false }
        connection.send(content: packet, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.queuedBytes = max(0, self.queuedBytes - packet.count) }
        })
        return true
    }

    public func receiveFrame() async throws -> Data {
        let header = try await receive(exactly: 4)
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length <= Self.maximumFrameSize else { throw TransportError.frameTooLarge(length) }
        if length == 0 { return Data() }
        return try await receive(exactly: length)
    }

    private func receive(exactly count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: Self.map(error))
                } else if let data, data.count == count {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: TransportError.closed)
                } else {
                    continuation.resume(throwing: TransportError.closed)
                }
            }
        }
    }

    public func cancel() {
        let (shouldCancel, continuation): (Bool, CheckedContinuation<Void, Error>?) = lock.withLock {
            guard !isCancelled else { return (false, nil) }
            isCancelled = true
            isReady = false
            let cont = readyContinuation
            readyContinuation = nil
            stateHandlers.removeAll()
            return (true, cont)
        }
        guard shouldCancel else { return }
        continuation?.resume(throwing: TransportError.closed)
        connection.cancel()
    }

    private static func lengthPrefix(_ count: Int) -> Data {
        var length = UInt32(count).bigEndian
        return Data(bytes: &length, count: 4)
    }
}
