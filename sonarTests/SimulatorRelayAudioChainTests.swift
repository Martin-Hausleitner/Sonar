import Foundation
@testable import Sonar
import XCTest

/// §1.6: the simulator-relay pipeline carries REAL audio. These tests guard
/// the receive-chain admission filter that keeps the 2 Hz keepalive out of
/// the Opus decoder while every genuine audio frame still reaches the
/// jitter buffer.
final class SimulatorRelayAudioChainTests: XCTestCase {
    /// The wiretap harness (`scripts/e2e/relay_wiretap.py`) and the relay
    /// assertions identify the keepalive by these exact bytes — a rename on
    /// either side silently breaks the E2E proof.
    func testKeepalivePayloadMatchesWireContract() {
        XCTAssertEqual(
            SessionCoordinator.simulatorRelayKeepalivePayload,
            Data("sonar-simulator-relay-frame".utf8)
        )
        XCTAssertEqual(SessionCoordinator.simulatorRelayKeepalivePayload.count, 27)
    }

    func testKeepaliveFrameIsNotEnqueued() {
        let keepalive = AudioFrame(
            seq: 7,
            payload: SessionCoordinator.simulatorRelayKeepalivePayload
        )
        XCTAssertFalse(
            SessionCoordinator.shouldEnqueueInbound(keepalive),
            "The keepalive is not Opus and must never reach the decoder"
        )
    }

    func testRealAudioFramesAreEnqueued() {
        let opusLike = AudioFrame(seq: 8, payload: Data([0x78, 0x01, 0x02, 0x03]))
        XCTAssertTrue(SessionCoordinator.shouldEnqueueInbound(opusLike))

        // Even an empty payload passes the filter — dropping is the decoder's
        // call, the filter only knows about the keepalive.
        let empty = AudioFrame(seq: 9, payload: Data())
        XCTAssertTrue(SessionCoordinator.shouldEnqueueInbound(empty))
    }
}
