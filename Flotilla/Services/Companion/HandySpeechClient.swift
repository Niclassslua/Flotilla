import CompanionKit
import Darwin
import Foundation
import os

protocol HandySpeechServing: Sendable {
    func capabilities() async -> CompanionSpeechEvent
    func start(_ request: CompanionSpeechStart) async -> CompanionSpeechEvent
    func audio(requestID: UUID, sequence: Int, pcm: Data) async -> CompanionSpeechEvent
    func finish(requestID: UUID) async -> CompanionSpeechEvent
    func cancel(requestID: UUID) async -> CompanionSpeechEvent
    func close() async
}

private enum HandySpeechError: Error {
    case unavailable
    case invalidResponse
}

private enum HandySpeechLog {
    static let logger = Logger(subsystem: "com.niclassslua.flotilla", category: "HandySpeech")
}

private final class HandySpeechSocket: @unchecked Sendable {
    private static let receiveTimeout = timeval(tv_sec: 60, tv_usec: 0)
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init() throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HandySpeechError.unavailable }
        // Handy is a direct-download app and publishes this endpoint in the
        // user's shared Application Support directory. Do not derive this
        // from Flotilla's application-support URL: sandboxed or containerized
        // builds would otherwise look in Flotilla's private container.
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Handy/transcription-v1.sock").path
        HandySpeechLog.logger.info("Connecting to Handy local transcription socket at \(path, privacy: .private(mask: .hash))")
        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw HandySpeechError.unavailable
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.initializeMemory(as: UInt8.self, repeating: 0)
            target.copyBytes(from: bytes)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            HandySpeechLog.logger.error("Handy socket connect failed: errno=\(errno)")
            Darwin.close(fd)
            throw HandySpeechError.unavailable
        }
        HandySpeechLog.logger.info("Connected to Handy local transcription socket")
        var noSigPipe: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE,
                              &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var receiveTimeout = Self.receiveTimeout
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO,
                              &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        self.fd = fd
    }

    deinit { Darwin.close(fd) }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.shutdown(fd, SHUT_RDWR)
    }

    func exchange(_ payload: Data, until expected: Set<String>) throws -> Data {
        try send(payload)
        while true {
            let response = try receive()
            guard let type = response["type"] as? String else { throw HandySpeechError.invalidResponse }
            if expected.contains(type) || type == "error" || type == "failed" {
                return try JSONSerialization.data(withJSONObject: response)
            }
        }
    }

    private func send(_ payload: Data) throws {
        guard payload.count <= 16 * 1024 else { throw HandySpeechError.invalidResponse }
        var length = UInt32(payload.count).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        try writeAll(header)
        try writeAll(payload)
    }

    private func receive() throws -> [String: Any] {
        let header = try readExactly(4)
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= 16 * 1024 else { throw HandySpeechError.invalidResponse }
        let payload = try readExactly(length)
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw HandySpeechError.invalidResponse
        }
        return object
    }

    private func readExactly(_ length: Int) throws -> Data {
        var data = Data(count: length)
        var offset = 0
        while offset < length {
            let count = data.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), length - offset)
            }
            if count == 0 { throw HandySpeechError.unavailable }
            if count < 0 {
                if errno == EINTR { continue }
                throw HandySpeechError.unavailable
            }
            offset += count
        }
        return data
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if count <= 0 {
                    if errno == EINTR { continue }
                    throw HandySpeechError.unavailable
                }
                offset += count
            }
        }
    }
}

actor HandySpeechClient: HandySpeechServing {
    private var socket: HandySpeechSocket?

    func capabilities() async -> CompanionSpeechEvent {
        var capabilitySocket: HandySpeechSocket?
        var phase = "opening socket"
        do {
            // A capability probe is independent of an active transcription.
            // Keep it off the actor's streaming socket slot so concurrent
            // startup/settings probes cannot close or replace a socket that
            // another probe is using.
            let opened = try await Task.detached(priority: .utility) {
                try HandySpeechSocket()
            }.value
            capabilitySocket = opened
            phase = "handshake"
            _ = try await exchange(opened,
                ["type": "hello", "version": "1.0.0"], until: ["hello"])
            phase = "capabilities request"
            let response = try await exchange(opened,
                ["type": "capabilities"], until: ["capabilities"])
            let status = response["status"] as? String ?? "unavailable"
            HandySpeechLog.logger.error("Handy capability response received: type=\(response["type"] as? String ?? "missing", privacy: .public), status=\(status, privacy: .public)")
            let event = CompanionSpeechEvent.capabilities(
                status: status,
                models: (response["models"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            )
            opened.close()
            HandySpeechLog.logger.info("Handy capability response received: \(status, privacy: .public)")
            return event
        } catch {
            capabilitySocket?.close()
            HandySpeechLog.logger.error("Handy capability check failed during \(phase, privacy: .public): \(String(describing: error), privacy: .public)")
            return .failed(requestID: nil, code: "unavailable", message: "Handy is unavailable on this Mac.", retryable: true)
        }
    }

    func start(_ request: CompanionSpeechStart) async -> CompanionSpeechEvent {
        do {
            let socket = try await connect()
            let corrections = request.spokenCorrections.map { ["spoken": $0.spoken, "written": $0.written] }
            let message: [String: Any] = [
                "type": "start", "requestID": request.requestID.uuidString,
                "mode": request.mode, "audioFormat": "pcm_s16le_16000_mono",
                "languageHints": request.languageHints,
                "verbatimTerms": request.verbatimTerms,
                "spokenCorrections": corrections
            ]
            let response = try await exchange(socket, message, until: ["started"])
            return event(response, requestID: request.requestID)
        } catch {
            socket?.close()
            socket = nil
            return .failed(requestID: request.requestID, code: "unavailable", message: "Handy could not start transcription.", retryable: true)
        }
    }

    func audio(requestID: UUID, sequence: Int, pcm: Data) async -> CompanionSpeechEvent {
        guard let socket else { return .failed(requestID: requestID, code: "unavailable", message: "Handy disconnected.", retryable: true) }
        do {
            let response = try await exchange(socket,
                ["type": "audio", "requestID": requestID.uuidString,
                 "sequence": sequence, "pcm": pcm.base64EncodedString()],
                until: ["audioAck", "slowDown"])
            return event(response, requestID: requestID)
        } catch {
            socket.close()
            self.socket = nil
            return .failed(requestID: requestID, code: "unavailable", message: "Handy disconnected.", retryable: true)
        }
    }

    func finish(requestID: UUID) async -> CompanionSpeechEvent {
        guard let socket else { return .failed(requestID: requestID, code: "unavailable", message: "Handy disconnected.", retryable: true) }
        do {
            let response = try await exchange(socket,
                ["type": "finish", "requestID": requestID.uuidString], until: ["final", "cancelled"])
            socket.close()
            self.socket = nil
            return event(response, requestID: requestID)
        } catch {
            socket.close()
            self.socket = nil
            return .failed(requestID: requestID, code: "engineFailed", message: "Transcription did not finish.", retryable: true)
        }
    }

    func cancel(requestID: UUID) async -> CompanionSpeechEvent {
        if let socket {
            _ = try? await exchange(socket,
                ["type": "cancel", "requestID": requestID.uuidString], until: ["cancelled", "ack"])
            socket.close()
            self.socket = nil
        }
        return .cancelled(requestID: requestID)
    }

    func close() async {
        socket?.close()
        socket = nil
    }

    private func connect() async throws -> HandySpeechSocket {
        if let socket { return socket }
        let opened = try await Task.detached(priority: .utility) {
            try HandySpeechSocket()
        }.value
        let hello = try await exchange(opened,
            ["type": "hello", "version": "1.0.0"], until: ["hello"])
        guard hello["type"] as? String == "hello" else {
            opened.close()
            throw HandySpeechError.invalidResponse
        }
        socket = opened
        return opened
    }

    private func event(_ reply: [String: Any], requestID: UUID) -> CompanionSpeechEvent {
        switch reply["type"] as? String {
        case "started":
            return .started(requestID: requestID, modelID: reply["modelID"] as? String ?? "")
        case "audioAck":
            return .audioAck(requestID: requestID, nextSequence: reply["nextSequence"] as? Int ?? 0)
        case "slowDown":
            return .slowDown(requestID: requestID, nextSequence: reply["nextSequence"] as? Int ?? 0)
        case "final":
            return .final(requestID: requestID, revision: reply["revision"] as? UInt64 ?? 0,
                          text: reply["text"] as? String ?? "")
        case "cancelled":
            return .cancelled(requestID: requestID)
        default:
            let error = reply["error"] as? [String: Any] ?? [:]
            return .failed(requestID: requestID, code: error["code"] as? String ?? "engineFailed",
                           message: error["message"] as? String ?? "Handy could not transcribe.",
                           retryable: error["retryable"] as? Bool ?? false)
        }
    }

    private func exchange(_ socket: HandySpeechSocket, _ message: [String: Any],
                          until expected: Set<String>) async throws -> [String: Any] {
        let payload = try JSONSerialization.data(withJSONObject: message)
        let reply = try await Task.detached(priority: .utility) {
            try socket.exchange(payload, until: expected)
        }.value
        guard let decoded = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw HandySpeechError.invalidResponse
        }
        return decoded
    }
}
