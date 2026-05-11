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

    func testRemovePairingTokenPlanDisconnectsMatchingBLEIdentifierAndClearsWritablePath() {
        let removed = UUID()
        let retained = UUID()

        let plan = BluetoothMeshTransport.removalPlan(
            forBLEIdentifier: removed.uuidString,
            connectedPeripheralIdentifiers: [removed, retained],
            writableCharacteristicIdentifiers: [removed, retained]
        )

        XCTAssertEqual(plan.peripheralIdentifiersToDisconnect, [removed])
        XCTAssertEqual(plan.writableCharacteristicIdentifiersToRemove, [removed])
    }

    func testPeerCallbackGuardRejectsForgottenPendingConnect() {
        let forgotten = UUID()

        let decision = BluetoothMeshTransport.peerCallbackDecision(
            peripheralIdentifier: forgotten,
            allowedBLEIdentifiers: [],
            expectedPeripheralIdentifiers: []
        )

        XCTAssertEqual(decision, .ignore)
    }

    func testPeerCallbackGuardAcceptsAllowedExpectedPeripheral() {
        let expected = UUID()

        let decision = BluetoothMeshTransport.peerCallbackDecision(
            peripheralIdentifier: expected,
            allowedBLEIdentifiers: [expected.uuidString],
            expectedPeripheralIdentifiers: [expected]
        )

        XCTAssertEqual(decision, .accept)
    }

    func testDisconnectMutationGuardIgnoresStaleForgottenDisconnect() {
        let forgotten = UUID()

        let decision = BluetoothMeshTransport.disconnectMutationDecision(
            peripheralIdentifier: forgotten,
            connectedPeripheralIdentifiers: [],
            writableCharacteristicIdentifiers: []
        )

        XCTAssertEqual(decision, .ignore)
    }

    func testDisconnectMutationGuardAcceptsKnownConnectedOrWritablePeripheral() {
        let connected = UUID()
        let writableOnly = UUID()

        XCTAssertEqual(
            BluetoothMeshTransport.disconnectMutationDecision(
                peripheralIdentifier: connected,
                connectedPeripheralIdentifiers: [connected],
                writableCharacteristicIdentifiers: []
            ),
            .accept
        )
        XCTAssertEqual(
            BluetoothMeshTransport.disconnectMutationDecision(
                peripheralIdentifier: writableOnly,
                connectedPeripheralIdentifiers: [],
                writableCharacteristicIdentifiers: [writableOnly]
            ),
            .accept
        )
    }
}
