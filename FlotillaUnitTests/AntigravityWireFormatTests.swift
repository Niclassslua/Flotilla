import XCTest
@testable import TranscriptKit

/// `AntigravityWireFormat` is the one piece of code every other Antigravity
/// capability depends on, so its core guarantee — parse then serialize
/// reproduces the input exactly — gets direct, dedicated coverage.
final class AntigravityWireFormatTests: XCTestCase {
    func testRoundTripsAnArbitraryMessageByteForByte() throws {
        let original = AntigravityWireFormat.serialize([
            AntigravityWireFormat.varintField(1, 14),
            AntigravityWireFormat.stringField(2, "hello, world"),
            AntigravityWireFormat.messageField(5, [
                AntigravityWireFormat.varintField(1, 12345),
                AntigravityWireFormat.stringField(2, "nested")
            ])
        ])

        let parsed = try AntigravityWireFormat.parse(original)
        let rebuilt = AntigravityWireFormat.serialize(parsed)

        XCTAssertEqual(rebuilt, original)
    }

    func testRoundTripsCapturedFieldOrderAndUnknownFieldsVerbatim() throws {
        // A field number this codec never decodes, mixed in with ones it
        // does — the whole point is that unknown fields survive untouched.
        let original = AntigravityWireFormat.serialize([
            AntigravityWireFormat.varintField(1, 132),
            Field(number: 99, wireType: 0, payload: AntigravityWireFormat.encodeVarint(9)),
            AntigravityWireFormat.stringField(2, "unchanged"),
            Field(number: 100, wireType: 2, payload: Data([0x01, 0x02, 0x03, 0xFF]))
        ])

        let parsed = try AntigravityWireFormat.parse(original)
        XCTAssertEqual(parsed.map(\.number), [1, 99, 2, 100], "field order is preserved")
        XCTAssertEqual(AntigravityWireFormat.serialize(parsed), original)
    }

    func testDecodesAndRebuildsAVarintAndAString() throws {
        let fields = try AntigravityWireFormat.parse(AntigravityWireFormat.serialize([
            AntigravityWireFormat.varintField(3, 987_654_321),
            AntigravityWireFormat.stringField(4, "some text")
        ]))

        XCTAssertEqual(AntigravityWireFormat.varint(fields, 3), 987_654_321)
        XCTAssertEqual(AntigravityWireFormat.string(fields, 4), "some text")
    }

    func testDecodesANestedMessage() throws {
        let fields = try AntigravityWireFormat.parse(AntigravityWireFormat.serialize([
            AntigravityWireFormat.messageField(20, [
                AntigravityWireFormat.stringField(1, "inner-a"),
                AntigravityWireFormat.varintField(2, 7)
            ])
        ]))

        let inner = AntigravityWireFormat.message(fields, 20)
        XCTAssertEqual(AntigravityWireFormat.string(inner, 1), "inner-a")
        XCTAssertEqual(AntigravityWireFormat.varint(inner, 2), 7)
    }

    func testMissingFieldsReturnNilRatherThanThrowing() throws {
        let fields = try AntigravityWireFormat.parse(AntigravityWireFormat.serialize([
            AntigravityWireFormat.varintField(1, 1)
        ]))

        XCTAssertNil(AntigravityWireFormat.string(fields, 99))
        XCTAssertNil(AntigravityWireFormat.varint(fields, 99))
        XCTAssertEqual(AntigravityWireFormat.message(fields, 99), [])
    }

    func testTruncatedInputThrowsRatherThanCrashing() {
        // A length-delimited tag claiming more bytes than actually follow.
        var data = AntigravityWireFormat.encodeVarint((2 << 3) | 2)
        data += AntigravityWireFormat.encodeVarint(50)
        data += Data([0x01, 0x02])

        XCTAssertThrowsError(try AntigravityWireFormat.parse(data))
    }
}

private typealias Field = AntigravityWireFormat.Field
