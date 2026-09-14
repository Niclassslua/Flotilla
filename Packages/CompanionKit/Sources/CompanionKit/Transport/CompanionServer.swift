import Foundation
import Network

/// Accepts phone connections, runs the handshake, and hands authenticated
/// sessions to its owner. Advertises itself over Bonjour for LAN discovery.
public final class CompanionServer: @unchecked Sendable {
    public static let bonjourType = "_flotilla-comp._tcp"
    public static let defaultPort: UInt16 = 48620

    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    /// A connected, authenticated phone.
    public struct Peer: Sendable {
        public let hello: ClientHello
        public let session: ServerSideSession
    }

    private let queue = DispatchQueue(label: "companion.server")
    private let lock = NSLock()
    private var listener: NWListener?
    private let context: @Sendable () -> Handshake.ServerContext
    private let onPeer: @Sendable (Peer) -> Void
    private let onStateChange: @Sendable (State) -> Void
    private let advertisesBonjour: Bool

    public init(
        advertisesBonjour: Bool = true,
        context: @escaping @Sendable () -> Handshake.ServerContext,
        onPeer: @escaping @Sendable (Peer) -> Void,
        onStateChange: @escaping @Sendable (State) -> Void = { _ in }
    ) {
        self.advertisesBonjour = advertisesBonjour
        self.context = context
        self.onPeer = onPeer
        self.onStateChange = onStateChange
    }

    /// Listens on `preferredPort`, or on any free port if it is taken.
    public func start(preferredPort: UInt16? = CompanionServer.defaultPort) {
        stop()
        onStateChange(.starting)
        do {
            let listener = try makeListener(port: preferredPort)
            install(listener, retryOnAnyPort: preferredPort != nil)
        } catch {
            onStateChange(.failed(error.localizedDescription))
        }
    }

    public func stop() {
        let current: NWListener? = lock.withLock {
            defer { listener = nil }
            return listener
        }
        current?.cancel()
    }

    private func makeListener(port: UInt16?) throws -> NWListener {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        if let port, let nwPort = NWEndpoint.Port(rawValue: port) {
            return try NWListener(using: parameters, on: nwPort)
        }
        return try NWListener(using: parameters)
    }

    private func install(_ listener: NWListener, retryOnAnyPort: Bool) {
        if advertisesBonjour {
            let context = context()
            let txt = NWTXTRecord(["macID": context.macID, "v": String(CompanionProtocol.version)])
            listener.service = NWListener.Service(name: context.macName, type: Self.bonjourType, txtRecord: txt)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                self.onStateChange(.listening(port: listener.port?.rawValue ?? 0))
            case .failed(let error):
                listener.cancel()
                if retryOnAnyPort, case .posix(let code) = error, code == .EADDRINUSE,
                   let fallback = try? self.makeListener(port: nil) {
                    self.lock.withLock { self.listener = fallback }
                    self.install(fallback, retryOnAnyPort: false)
                } else {
                    self.onStateChange(.failed(error.debugDescription))
                }
            case .cancelled:
                self.onStateChange(.stopped)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.accept(connection) }
        }
        lock.withLock { self.listener = listener }
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) async {
        let frames = FrameConnection(connection: connection, label: "companion.peer")
        do {
            try await frames.start(timeout: .seconds(10))
            let first = try await HandshakeIO.receive(on: frames, timeout: .seconds(10))
            guard case .clientHello(let hello) = first else { throw RejectReason.malformed }
            let result: Handshake.ServerResult
            do {
                result = try Handshake.respond(to: hello, context: context())
            } catch let reason as RejectReason {
                try? await HandshakeIO.send(.serverReject(ServerReject(reason: reason, supportedVersion: CompanionProtocol.version)), on: frames)
                // Give the reject a moment to flush before closing.
                try? await Task.sleep(for: .milliseconds(200))
                frames.cancel()
                return
            }
            try await HandshakeIO.send(result.reply, on: frames)
            let session = ServerSideSession(frames: frames, channel: result.channel)
            onPeer(Peer(hello: result.hello, session: session))
        } catch {
            frames.cancel()
        }
    }
}
