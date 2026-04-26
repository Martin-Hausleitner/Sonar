import XCTest
@testable import Sonar

final class AudioFrameTests: XCTestCase {

    // MARK: - Init

    func testInitStoresProperties() {
        let payload = Data([0x01, 0x02, 0x03])
        let frame = AudioFrame(seq: 42, timestamp: 99, payload: payload, codec: .opus)
        XCTAssertEqual(frame.seq, 42)
        XCTAssertEqual(frame.timestamp, 99)
        XCTAssertEqual(frame.payload, payload)
        XCTAssertEqual(frame.codecID, .opus)
    }

    func testInitDefaultCodecIsOpus() {
        let frame = AudioFrame(seq: 1, payload: Data([0xFF]))
        XCTAssertEqual(frame.codecID, .opus)
    }

    func testInitLyraV2Codec() {
        let frame = AudioFrame(seq: 7, payload: Data([0xAB]), codec: .lyraV2)
        XCTAssertEqual(frame.codecID, .lyraV2)
    }

    // MARK: - wireData encoding / decoding round-trip

    func testWireDataRoundTrip() throws {
        let payload = Data([0x10, 0x20, 0x30, 0x40])
        let original = AudioFrame(seq: 1234, timestamp: 9876543210, payload: payload, codec: .opus)
        let wire = original.wireData

        let decoded = try XCTUnwrap(AudioFrame(wireData: wire))
        XCTAssertEqual(decoded.seq, original.seq)
        XCTAssertEqual(decoded.timestamp, original.timestamp)
        XCTAssertEqual(decoded.payload, original.payload)
        XCTAssertEqual(decoded.codecID, original.codecID)
    }

    func testWireDataRoundTripLyraV2() throws {
        let payload = Data(repeating: 0xCC, count: 40)
        let original = AudioFrame(seq: 0, timestamp: 0, payload: payload, codec: .lyraV2)
        let decoded = try XCTUnwrap(AudioFrame(wireData: original.wireData))
        XCTAssertEqual(decoded.codecID, .lyraV2)
        XCTAssertEqual(decoded.payload, payload)
    }

    func testWireDataMinimumLength() {
        // Header is 13 bytes: 4B seq + 8B ts + 1B codec
        let frame = AudioFrame(seq: 0, payload: Data())
        XCTAssertEqual(frame.wireData.count, 13)
    }

    func testWireDataPayloadAppended() {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let frame = AudioFrame(seq: 0, payload: payload)
        XCTAssertEqual(frame.wireData.count, 13 + payload.count)
    }

    // MARK: - wireData with too-short data returns nil

    func testWireDataTooShortReturnsNil() {
        XCTAssertNil(AudioFrame(wireData: Data()))
        XCTAssertNil(AudioFrame(wireData: Data(repeating: 0, count: 12)))
    }

    func testWireDataExactly13BytesIsValid() {
        // 13 bytes with codec 0 (opus) and empty payload
        var data = Data(count: 13)
        // seq = 0, ts = 0, codec = 0 (opus) — all zeros is valid
        XCTAssertNotNil(AudioFrame(wireData: data))

        // Set codec byte to an invalid value
        data[12] = 0xFF
        XCTAssertNil(AudioFrame(wireData: data), "Unknown codec should return nil")
    }

    // MARK: - Seq wraps around (UInt32 overflow)

    func testSeqWrapsAroundOnOverflow() {
        let max = AudioFrame(seq: UInt32.max, payload: Data([0x01]))
        let wire = max.wireData
        let decoded = AudioFrame(wireData: wire)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.seq, UInt32.max)
    }

    func testSeqBigEndianEncoding() {
        // seq = 1 should be stored as [0x00, 0x00, 0x00, 0x01]
        let frame = AudioFrame(seq: 1, timestamp: 0, payload: Data())
        let wire = frame.wireData
        XCTAssertEqual(wire[0], 0x00)
        XCTAssertEqual(wire[1], 0x00)
        XCTAssertEqual(wire[2], 0x00)
        XCTAssertEqual(wire[3], 0x01)
    }

    func testSeqCounterArithmetic() {
        // Simulate overflow: UInt32.max &+ 1 == 0
        var counter: UInt32 = UInt32.max
        counter &+= 1
        XCTAssertEqual(counter, 0)
    }
}
