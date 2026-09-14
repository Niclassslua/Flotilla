import Foundation

/// A minimal, schema-free protobuf wire-format reader/writer.
///
/// Antigravity's conversation state (see `FORMAT.md` in this directory) has no
/// published schema, so this does not attempt to model one. It parses a
/// message into an ordered list of `(field number, wire type, payload)`
/// triples — preserving every byte of fields nobody has decoded — and lets
/// callers rewrite only the handful of fields ``AntigravityTranscriptCodec``
/// actually understands. Parsing a message and serializing it straight back
/// reproduces the input byte for byte; `AntigravityWireFormatTests` checks
/// this directly, since it is the property every other guarantee in this
/// codec depends on.
enum AntigravityWireFormat {
    /// One field as it appears on the wire. `payload` is the field's raw
    /// encoded value: for wire type 2 (length-delimited) it is the inner
    /// bytes with no length prefix; for every other wire type it is the
    /// value's own encoded bytes, ready to be written back verbatim.
    struct Field: Equatable {
        var number: Int
        var wireType: Int
        var payload: Data
    }

    enum WireError: Error, Equatable {
        case truncated
        case unsupportedWireType(Int)
    }

    static func parse(_ data: Data) throws -> [Field] {
        var fields: [Field] = []
        var index = data.startIndex
        while index < data.endIndex {
            let tag = try readVarint(data, &index)
            let number = Int(tag >> 3)
            let wireType = Int(tag & 0x7)
            let payload: Data
            switch wireType {
            case 0:
                let start = index
                _ = try readVarint(data, &index)
                payload = Data(data[start..<index])
            case 1:
                payload = try readFixed(data, &index, count: 8)
            case 2:
                let length = Int(try readVarint(data, &index))
                guard data.distance(from: index, to: data.endIndex) >= length else { throw WireError.truncated }
                let end = data.index(index, offsetBy: length)
                payload = Data(data[index..<end])
                index = end
            case 5:
                payload = try readFixed(data, &index, count: 4)
            default:
                throw WireError.unsupportedWireType(wireType)
            }
            fields.append(Field(number: number, wireType: wireType, payload: payload))
        }
        return fields
    }

    static func serialize(_ fields: [Field]) -> Data {
        var out = Data()
        for field in fields {
            out += encodeVarint(UInt64((field.number << 3) | field.wireType))
            if field.wireType == 2 {
                out += encodeVarint(UInt64(field.payload.count))
            }
            out += field.payload
        }
        return out
    }

    // MARK: - Reading a specific field out of an already-parsed message

    static func first(_ fields: [Field], _ number: Int) -> Field? {
        fields.first { $0.number == number }
    }

    static func string(_ fields: [Field], _ number: Int) -> String? {
        first(fields, number).flatMap { String(data: $0.payload, encoding: .utf8) }
    }

    static func varint(_ fields: [Field], _ number: Int) -> UInt64? {
        guard let field = first(fields, number) else { return nil }
        var index = field.payload.startIndex
        return try? readVarint(field.payload, &index)
    }

    static func message(_ fields: [Field], _ number: Int) -> [Field] {
        guard let field = first(fields, number) else { return [] }
        return (try? parse(field.payload)) ?? []
    }

    // MARK: - Building fields

    static func stringField(_ number: Int, _ value: String) -> Field {
        Field(number: number, wireType: 2, payload: Data(value.utf8))
    }

    static func varintField(_ number: Int, _ value: UInt64) -> Field {
        Field(number: number, wireType: 0, payload: encodeVarint(value))
    }

    static func messageField(_ number: Int, _ fields: [Field]) -> Field {
        Field(number: number, wireType: 2, payload: serialize(fields))
    }

    // MARK: - Varint primitives

    static func encodeVarint(_ value: UInt64) -> Data {
        var value = value
        var out = Data()
        while true {
            let byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 {
                out.append(byte | 0x80)
            } else {
                out.append(byte)
                return out
            }
        }
    }

    private static func readVarint(_ data: Data, _ index: inout Data.Index) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < data.endIndex else { throw WireError.truncated }
            let byte = data[index]
            index = data.index(after: index)
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    private static func readFixed(_ data: Data, _ index: inout Data.Index, count: Int) throws -> Data {
        guard data.distance(from: index, to: data.endIndex) >= count else { throw WireError.truncated }
        let end = data.index(index, offsetBy: count)
        let value = Data(data[index..<end])
        index = end
        return value
    }
}
