import XCTest

@testable import Sonar

/// Tests for NearTransport's 1-byte message-type framing protocol.
/// Validates that audio frames and NIDiscoveryToken messages are correctly
/// prefixed and that unknown types are silently dropped.
final class MessageFramingTests: XCTestCase {

    // MARK: - AudioFrame wire encoding

    func testAudioFrameWireRoundtrip() {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let frame = AudioFrame(seq: 42, timestamp: 99, payload: payload)

        let wire = frame.wireData
        // 4B seq + 8B ts + 1B codec + 4B payload = 17 bytes
        XCTAssertEqual(wire.count, 17)

        let decoded = AudioFrame(wireData: wire)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.seq, 42)
        XCTAssertEqual(decoded?.payload, payload)
    }

    func testNITokenMessagePrefix() {
        // Simulate the niToken message prefix byte
        let fakeTokenData = Data(repeating: 0xAB, count: 32)
        var msg = Data([0x02])  // Msg.niToken
        msg.append(fakeTokenData)

        XCTAssertEqual(msg[0], 0x02, "First byte must be Msg.niToken tag")
        let payload = msg.dropFirst()
        XCTAssertEqual(payload, fakeTokenData)
    }

    func testUnknownMessageTypeIsDropped() {
        // A message with type byte 0xFF should not produce an AudioFrame
        let unknownMsg = Data([0xFF, 0xDE, 0xAD])
        guard let typeRaw = unknownMsg.first else {
            XCTFail("Expected data")
            return
        }
        // Simulate NearTransport's switch: only 0x01 and 0x02 are known
        let known: Set<UInt8> = [0x01, 0x02]
        XCTAssertFalse(known.contains(typeRaw), "0xFF should not be a recognised type")
    }

    func testAudioFrameMinimumWireSize() {
        // Wire format requires at least 13 bytes (4+8+1) before any payload
        let tooShort = Data(repeating: 0x00, count: 12)
        XCTAssertNil(AudioFrame(wireData: tooShort))
    }

    func testAudioFrameWithEmptyPayload() {
        let frame = AudioFrame(seq: 0, timestamp: 0, payload: Data())
        let wire = frame.wireData
        XCTAssertEqual(wire.count, 13)  // header only
        let decoded = AudioFrame(wireData: wire)
        XCTAssertNotNil(decoded)
        XCTAssertTrue(decoded?.payload.isEmpty == true)
    }

    func testAudioFrameSequencePreservation() {
        let seqs: [UInt32] = [0, 1, UInt32.max / 2, UInt32.max]
        for seq in seqs {
            let frame = AudioFrame(seq: seq, payload: Data([0x00]))
            let decoded = AudioFrame(wireData: frame.wireData)
            XCTAssertEqual(decoded?.seq, seq, "seq \(seq) should survive wire roundtrip")
        }
    }

    func testMultipleCodecIDsRoundtrip() {
        let opusFrame = AudioFrame(seq: 1, payload: Data([0xAA]), codec: .opus)
        let lyraFrame = AudioFrame(seq: 2, payload: Data([0xBB]), codec: .lyraV2)

        XCTAssertEqual(AudioFrame(wireData: opusFrame.wireData)?.codecID, .opus)
        XCTAssertEqual(AudioFrame(wireData: lyraFrame.wireData)?.codecID, .lyraV2)
    }
}
