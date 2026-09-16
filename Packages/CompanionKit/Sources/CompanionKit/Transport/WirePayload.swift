import Foundation
import Compression

/// Version-2 plaintext envelope, authenticated by the existing sealed channel.
/// Compression happens before encryption; decoded size is always bounded.
enum WirePayload {
    static let maximumSize = FrameConnection.maximumFrameSize - 24
    private static let minimumCompressionSize = 16 * 1024

    static func encode(_ json: Data) throws -> Data {
        guard json.count <= maximumSize - 5 else { throw TransportError.frameTooLarge(json.count + 29) }
        if json.count >= minimumCompressionSize, let compressed = compress(json),
           compressed.count * 10 < json.count * 9 {
            var envelope = Data([1])
            var length = UInt32(json.count).bigEndian
            envelope.append(Data(bytes: &length, count: 4))
            envelope.append(compressed)
            if envelope.count <= maximumSize { return envelope }
        }
        return Data([0]) + json
    }

    static func decode(_ data: Data) throws -> Data {
        guard let kind = data.first else { throw TransportError.closed }
        switch kind {
        case 0:
            return Data(data.dropFirst())
        case 1:
            guard data.count >= 5 else { throw TransportError.closed }
            let length = data.dropFirst().prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= maximumSize - 5 else { throw TransportError.frameTooLarge(length) }
            let source = Data(data.dropFirst(5))
            var decoded = Data(count: length)
            let count = decoded.withUnsafeMutableBytes { target in
                source.withUnsafeBytes { input in
                    compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, length,
                                              input.bindMemory(to: UInt8.self).baseAddress!, source.count,
                                              nil, COMPRESSION_LZFSE)
                }
            }
            guard count == length else { throw TransportError.closed }
            return decoded
        default:
            throw TransportError.closed
        }
    }

    private static func compress(_ data: Data) -> Data? {
        let capacity = data.count
        var output = Data(count: capacity)
        let count = output.withUnsafeMutableBytes { target in
            data.withUnsafeBytes { input in
                compression_encode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          input.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_LZFSE)
            }
        }
        guard count > 0 else { return nil }
        output.count = count
        return output
    }
}
