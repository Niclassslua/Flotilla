import Foundation
import Network

/// An established, encrypted message stream: typed messages in, typed messages
/// out. The Mac holds one per connected phone (`SecureSession<ServerMessage,
/// ClientMessage>`), the phone one per Mac.
public final class SecureSession<Outgoing: Encodable & Sendable, Incoming: Decodable & Sendable>: @unchecked Sendable {
    private let frames: FrameConnection
    private let lock = NSLock()
    private var channel: SecureChannel
    private var isClosed = false
    private var closeHandlers: [@Sendable (Error?) -> Void] = []

    /// Incoming messages. Finishes when the connection closes; finishes with
    /// an error when it fails or a frame doesn't authenticate.
    public let messages: AsyncThrowingStream<Incoming, Error>
    private let continuation: AsyncThrowingStream<Incoming, Error>.Continuation

    init(frames: FrameConnection, channel: SecureChannel) {
        self.frames = frames
        self.channel = channel
        (messages, continuation) = AsyncThrowingStream.makeStream(of: Incoming.self)
        frames.onStateChange { [weak self] state in
            switch state {
            case .failed(let error):
                self?.close(error: FrameConnection.map(error))
            case .cancelled:
                self?.close(error: nil)
            default:
                break
            }
        }
        Task { [weak self] in await self?.receiveLoop() }
    }

    public var endpoint: NWEndpoint? { frames.connection.currentPath?.remoteEndpoint }

    /// Seals and enqueues atomically, so counters match the wire order.
    public func send(_ message: Outgoing) throws {
        let plaintext = try CompanionJSON.encode(message)
        try lock.withLock {
            guard !isClosed else { throw TransportError.closed }
            let sealed = try channel.seal(plaintext)
            frames.enqueue(sealed)
        }
    }

    public func onClose(_ handler: @escaping @Sendable (Error?) -> Void) {
        let alreadyClosed = lock.withLock {
            if isClosed { return true }
            closeHandlers.append(handler)
            return false
        }
        if alreadyClosed { handler(nil) }
    }

    public func close(error: Error? = nil) {
        let handlers: [@Sendable (Error?) -> Void]? = lock.withLock {
            guard !isClosed else { return nil }
            isClosed = true
            defer { closeHandlers = [] }
            return closeHandlers
        }
        guard let handlers else { return }
        frames.cancel()
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        handlers.forEach { $0(error) }
    }

    private func receiveLoop() async {
        while true {
            do {
                let frame = try await frames.receiveFrame()
                let plaintext = try lock.withLock { try channel.open(frame) }
                let message = try CompanionJSON.decode(Incoming.self, from: plaintext)
                continuation.yield(message)
            } catch TransportError.closed {
                close()
                return
            } catch {
                close(error: error)
                return
            }
        }
    }
}

public typealias ServerSideSession = SecureSession<ServerMessage, ClientMessage>
public typealias ClientSideSession = SecureSession<ClientMessage, ServerMessage>

enum HandshakeIO {
    static func send(_ frame: HandshakeFrame, on connection: FrameConnection) async throws {
        try await connection.send(CompanionJSON.encode(frame))
    }

    static func receive(on connection: FrameConnection, timeout: Duration) async throws -> HandshakeFrame {
        try await withThrowingTaskGroup(of: HandshakeFrame.self) { group in
            group.addTask {
                let data = try await connection.receiveFrame()
                guard let frame = try? CompanionJSON.decode(HandshakeFrame.self, from: data) else {
                    throw HandshakeError.malformedFrame
                }
                return frame
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TransportError.timedOut
            }
            defer { group.cancelAll() }
            guard let frame = try await group.next() else { throw TransportError.closed }
            return frame
        }
    }
}
