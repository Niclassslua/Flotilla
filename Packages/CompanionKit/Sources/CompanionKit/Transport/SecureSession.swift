import Foundation
import Network
import os

/// An established, encrypted message stream: typed messages in, typed messages
/// out. The Mac holds one per connected phone (`SecureSession<ServerMessage,
/// ClientMessage>`), the phone one per Mac.
public final class SecureSession<Outgoing: Encodable & Sendable, Incoming: Decodable & Sendable>: @unchecked Sendable {
    private static var performance: Logger { Logger(subsystem: "com.niclassslua.flotilla", category: "CompanionPerformance") }
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

    public var endpoint: NWEndpoint? {
        guard frames.isConnected else { return nil }
        return frames.connection.currentPath?.remoteEndpoint
    }

    /// Seals and enqueues atomically, so counters match the wire order.
    public func send(_ message: Outgoing) throws {
        let started = Date()
        let json = try CompanionJSON.encode(message)
        let plaintext = try WirePayload.encode(json)
        // The channel adds an 8-byte counter and a 16-byte authentication tag.
        // Reject locally instead of enqueueing a frame that closes the peer.
        guard plaintext.count <= WirePayload.maximumSize else {
            throw TransportError.frameTooLarge(plaintext.count + 24)
        }
        try lock.withLock {
            guard !isClosed else { throw TransportError.closed }
            let sealed = try channel.seal(plaintext)
            guard frames.enqueue(sealed) else { throw TransportError.backpressure }
        }
        if json.count > 16 * 1024 {
            Self.performance.debug("outbound raw=\(json.count) wire=\(plaintext.count + 24) duration=\(Date().timeIntervalSince(started), format: .fixed(precision: 4))s")
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
                let started = Date()
                let plaintext = try lock.withLock { try channel.open(frame) }
                let message = try CompanionJSON.decode(Incoming.self, from: WirePayload.decode(plaintext))
                if frame.count > 16 * 1024 {
                    Self.performance.debug("decoded frame bytes=\(frame.count) duration=\(Date().timeIntervalSince(started), format: .fixed(precision: 4))s")
                }
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
