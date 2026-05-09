@testable import Sonar
import XCTest

final class BluetoothMeshTransportTests: XCTestCase {
    func testBLEFrameRoundTripUsesAudioFrameWireData() {
        let frame = AudioFrame(seq: 99, payload: Data([0x01, 0x02, 0x03]), codec: .opus)

        let encoded = BluetoothMeshTransport.encodeBLEFrame(frame)
        let decoded = BluetoothMeshTransport.decodeBLEFrame(encoded)

        XCTAssertEqual(decoded?.seq, 99)
        XCTAssertEqual(decoded?.payload, Data([0x01, 0x02, 0x03]))
    }

    func testInvalidBLEFrameReturnsNil() {
        XCTAssertNil(BluetoothMeshTransport.decodeBLEFrame(Data([0x00, 0x01])))
    }
}
