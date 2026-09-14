import Foundation
import Network

/// Somewhere to try reaching a Mac.
public struct ConnectTarget: Hashable, Sendable {
    public var path: NetworkPath
    /// What the user sees: `192.168.1.20`, `Studio (Bonjour)`, `100.101.5.3`.
    public var label: String
    public var endpoint: NWEndpoint

    public init(path: NetworkPath, label: String, endpoint: NWEndpoint) {
        self.path = path
        self.label = label
        self.endpoint = endpoint
    }

    public init?(_ candidate: HostCandidate) {
        guard let port = NWEndpoint.Port(rawValue: candidate.port) else { return nil }
        self.init(path: candidate.kind.path, label: candidate.host, endpoint: .hostPort(host: NWEndpoint.Host(candidate.host), port: port))
    }
}

/// How one target fared while connecting.
public enum AttemptStatus: Hashable, Sendable {
    case connecting
    case connected
    case failed(TransportError)
    /// Another target won the race first.
    case abandoned
}

public enum ConnectError: Error, Equatable, Sendable {
    case noTargets
    /// Every target failed; the per-target reasons are in the attempt log.
    case unreachable([ConnectTarget: TransportError])
    /// A Mac answered but refused or failed the handshake.
    case handshake(HandshakeError)
    case transport(TransportError)
}

public enum CompanionClient {
    /// Races TCP connections to every target, runs the handshake over the
    /// first one that opens, and returns the encrypted session.
    ///
    /// Only the TCP connect is raced. The handshake runs once, on the winner:
    /// a pairing secret is single-use, so two parallel handshakes would burn it.
    public static func connect(
        to targets: [ConnectTarget],
        hello makeHello: @Sendable () throws -> Handshake.ClientState,
        pinnedMacKey: Data,
        connectTimeout: Duration = .seconds(6),
        onAttempt: @escaping @Sendable (ConnectTarget, AttemptStatus) -> Void = { _, _ in }
    ) async throws -> (session: ClientSideSession, target: ConnectTarget, serverHello: ServerHello) {
        guard !targets.isEmpty else { throw ConnectError.noTargets }

        let (frames, winner) = try await race(targets, timeout: connectTimeout, onAttempt: onAttempt)
        do {
            let state = try makeHello()
            try await HandshakeIO.send(.clientHello(state.hello), on: frames)
            let reply = try await HandshakeIO.receive(on: frames, timeout: .seconds(10))
            let (channel, serverHello) = try Handshake.completeClient(state, reply: reply, pinnedMacKey: pinnedMacKey)
            return (ClientSideSession(frames: frames, channel: channel), winner, serverHello)
        } catch let error as HandshakeError {
            frames.cancel()
            throw ConnectError.handshake(error)
        } catch let error as TransportError {
            frames.cancel()
            throw ConnectError.transport(error)
        } catch {
            frames.cancel()
            throw ConnectError.handshake(.malformedFrame)
        }
    }

    private static func race(
        _ targets: [ConnectTarget],
        timeout: Duration,
        onAttempt: @escaping @Sendable (ConnectTarget, AttemptStatus) -> Void
    ) async throws -> (FrameConnection, ConnectTarget) {
        try await withThrowingTaskGroup(of: (ConnectTarget, Result<FrameConnection, TransportError>).self) { group in
            for target in targets {
                group.addTask {
                    onAttempt(target, .connecting)
                    let frames = FrameConnection(endpoint: target.endpoint)
                    do {
                        try await frames.start(timeout: timeout)
                        return (target, .success(frames))
                    } catch let error as TransportError {
                        frames.cancel()
                        return (target, .failure(error))
                    } catch {
                        frames.cancel()
                        return (target, .failure(Task.isCancelled ? .closed : .unreachable(error.localizedDescription)))
                    }
                }
            }

            var failures: [ConnectTarget: TransportError] = [:]
            var winner: (FrameConnection, ConnectTarget)?
            for try await (target, result) in group {
                switch result {
                case .success(let frames):
                    if winner == nil {
                        winner = (frames, target)
                        onAttempt(target, .connected)
                        group.cancelAll()
                    } else {
                        frames.cancel()
                        onAttempt(target, .abandoned)
                    }
                case .failure(let error):
                    if winner == nil {
                        failures[target] = error
                        onAttempt(target, .failed(error))
                    } else {
                        onAttempt(target, .abandoned)
                    }
                }
            }
            if let winner { return winner }
            throw ConnectError.unreachable(failures)
        }
    }
}
