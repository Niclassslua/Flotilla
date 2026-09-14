import Foundation
import Network
import CryptoKit

enum ProviderConnectionError: LocalizedError {
    case disconnected
    case timeout
    case invalidResponse
    case rejected(String)
    case requestFailed(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .disconnected: "The provider connection is unavailable."
        case .timeout: "The provider did not respond in time."
        case .invalidResponse: "The provider returned an invalid response."
        case .rejected(let message): message
        case .requestFailed(_, let message): message
        }
    }
}

@MainActor
protocol ProviderRPCServing: AnyObject {
    var onMessage: ([String: Any]) -> Void { get set }
    var onDisconnect: () -> Void { get set }
    func connect(socketPath: String) async throws
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any]
    func reply(id: Any, result: [String: Any]) throws
    func close()
}

/// Codex's Unix listener speaks RFC 6455, rather than newline-delimited RPC.
/// All mutable protocol state stays on the main actor; Network callbacks
/// transfer only bytes. The socket lives in a user-only directory.
@MainActor
final class ProviderRPC: ProviderRPCServing {
    var onMessage: ([String: Any]) -> Void = { _ in }
    var onDisconnect: () -> Void = {}
    private var connection: NWConnection?
    private var buffer = Data()
    private var fragment = Data()
    private var upgraded = false
    private var opening: CheckedContinuation<Void, Error>?
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var nextID = 0
    private var expectedAccept = ""
    private let queue = DispatchQueue(label: "companion.provider-rpc")
    private static let maximumMessageSize = 8 * 1024 * 1024

    func connect(socketPath: String) async throws {
        close()
        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        self.connection = connection
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        expectedAccept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        try await withCheckedThrowingContinuation { continuation in
            opening = continuation
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                Task { @MainActor in
                    guard let self, let connection, self.connection === connection else { return }
                    switch state {
                    case .ready:
                        let header = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(key)\r\n\r\n"
                        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
                        self.receive(connection)
                    case .failed, .cancelled:
                        self.close()
                    default: break
                    }
                }
            }
            connection.start(queue: queue)
            Task { [weak self, weak connection] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, let connection, self.connection === connection, self.opening != nil else { return }
                self.close(error: ProviderConnectionError.timeout)
            }
        }
        _ = try await request("initialize", params: [
            "clientInfo": ["name": "flotilla_companion", "version": "1.0"],
            "capabilities": ["experimentalApi": true]
        ])
        try send(["method": "initialized"])
    }

    func request(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        guard upgraded else { throw ProviderConnectionError.disconnected }
        nextID += 1
        let id = nextID
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try send(["id": id, "method": method, "params": params]) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.pending.removeValue(forKey: id)?.resume(throwing: ProviderConnectionError.timeout)
            }
        }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func reply(id: Any, result: [String: Any]) throws {
        try send(["id": id, "result": result])
    }

    func close() { close(error: ProviderConnectionError.disconnected) }

    func close(error: Error) {
        let old = connection
        connection = nil
        old?.cancel()
        upgraded = false
        buffer.removeAll()
        fragment.removeAll()
        opening?.resume(throwing: error)
        opening = nil
        let requests = pending
        pending.removeAll()
        for request in requests.values { request.resume(throwing: error) }
        if old != nil { onDisconnect() }
    }

    private func send(_ object: [String: Any]) throws {
        guard upgraded, connection != nil else { throw ProviderConnectionError.disconnected }
        let data = try JSONSerialization.data(withJSONObject: object)
        sendFrame(data, opcode: 1)
    }

    private func sendFrame(_ data: Data, opcode: UInt8) {
        var frame = Data([0x80 | opcode])
        let count = data.count
        if count < 126 { frame.append(0x80 | UInt8(count)) }
        else if count <= 65535 {
            frame.append(0xFE)
            frame.append(UInt8(count >> 8)); frame.append(UInt8(count & 255))
        } else {
            frame.append(0xFF)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((UInt64(count) >> shift) & 255)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: data.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        connection?.send(content: frame, completion: .contentProcessed { [weak self] error in
            if error != nil { Task { @MainActor in self?.close() } }
        })
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, complete, error in
            Task { @MainActor in
                guard let self, let connection, self.connection === connection else { return }
                if let data { self.buffer.append(data); self.consume() }
                if complete || error != nil { self.close() }
                else if self.connection === connection { self.receive(connection) }
            }
        }
    }

    private func consume() {
        if !upgraded {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 16 * 1024 { close(error: ProviderConnectionError.invalidResponse) }
                return
            }
            let header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            guard header.hasPrefix("HTTP/1.1 101"),
                  header.lowercased().contains("sec-websocket-accept: \(expectedAccept.lowercased())") else {
                close(error: ProviderConnectionError.invalidResponse); return
            }
            buffer = Data(buffer[end.upperBound...])
            upgraded = true
            opening?.resume(); opening = nil
        }
        while buffer.count >= 2 {
            let bytes = [UInt8](buffer)
            let final = bytes[0] & 0x80 != 0
            let opcode = bytes[0] & 0x0F
            let masked = bytes[1] & 0x80 != 0
            var size = UInt64(bytes[1] & 0x7F)
            var offset = 2
            if size == 126 {
                guard bytes.count >= 4 else { return }
                size = UInt64(bytes[2]) << 8 | UInt64(bytes[3]); offset = 4
            } else if size == 127 {
                guard bytes.count >= 10 else { return }
                size = bytes[2..<10].reduce(0) { $0 << 8 | UInt64($1) }; offset = 10
            }
            guard size <= Self.maximumMessageSize else { close(error: ProviderConnectionError.invalidResponse); return }
            let maskOffset = offset
            if masked { offset += 4 }
            guard bytes.count >= offset + Int(size) else { return }
            var payload = Data(bytes[offset..<(offset + Int(size))])
            if masked { payload = Data(payload.enumerated().map { $0.element ^ bytes[maskOffset + $0.offset % 4] }) }
            buffer = Data(bytes[(offset + Int(size))...])
            switch opcode {
            case 8: close(); return
            case 9: sendFrame(payload, opcode: 10)
            case 10: break
            case 0, 1:
                fragment.append(payload)
                guard fragment.count <= Self.maximumMessageSize else { close(error: ProviderConnectionError.invalidResponse); return }
                if final {
                    if let object = try? JSONSerialization.jsonObject(with: fragment) as? [String: Any] {
                        if object["method"] == nil, let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
                            if let error = object["error"] as? [String: Any] {
                                continuation.resume(throwing: ProviderConnectionError.requestFailed(code: error["code"] as? Int ?? 0, message: error["message"] as? String ?? "Provider request failed."))
                            } else {
                                do { continuation.resume(returning: try JSONSerialization.data(withJSONObject: object["result"] as? [String: Any] ?? [:])) }
                                catch { continuation.resume(throwing: error) }
                            }
                        } else { onMessage(object) }
                    }
                    fragment.removeAll()
                }
            default: close(error: ProviderConnectionError.invalidResponse); return
            }
        }
    }
}
