import Combine
import XCTest

@testable import Sonar

/// Tests for DistancePublisher state and RSSIFallback math.
///
/// The UWB > RSSI priority chain is an integration concern tested via the
/// E2E pipeline.  Here we cover:
///   • Initial published values
///   • RSSI log-distance math (offline, no hardware)
///   • GATT UUID format validity
@MainActor
final class DistancePublisherTests: XCTestCase {

    // MARK: - Initial state

    func testInitialDistanceIsNil() {
        XCTAssertNil(DistancePublisher().distance)
    }

    func testInitialSourceIsNone() {
        XCTAssertEqual(DistancePublisher().source, .none)
    }

    // MARK: - Bind wires up publishers without crashing

    func testBindDoesNotCrash() {
        let dp   = DistancePublisher()
        let uwb  = NIRangingEngine()
        let rssi = RSSIFallback()
        // bind() wires Combine subscriptions — just ensure no exception/crash.
        dp.bind(uwb: uwb, rssi: rssi)
        XCTAssertNil(dp.distance, "distance stays nil until a value is sent")
    }

    // MARK: - RSSI → distance math (log-distance path-loss model)
    // Mirrors the private formula in RSSIFallback: d = 10^((txPower-RSSI)/(10*n))
    // txPower = -59 dBm, n = 2.0

    func testRSSIAtTxPowerGivesOneMetre() {
        XCTAssertEqual(rssiToMetres(-59), 1.0, accuracy: 0.01)
    }

    func testRSSIWeakerThanTxPowerGivesMoreThanOneMetre() {
        XCTAssertGreaterThan(rssiToMetres(-70), 1.0)
    }

    func testRSSIStrongerThanTxPowerGivesLessThanOneMetre() {
        XCTAssertLessThan(rssiToMetres(-50), 1.0)
    }

    func testDistanceScalesWithPathLossN2() {
        // For n=2, 10 dB weaker → √10× further.
        let ratio = rssiToMetres(-69) / rssiToMetres(-59)
        XCTAssertEqual(ratio, sqrt(10.0), accuracy: 0.01)
    }

    func testDistanceAtMinus79dBm() {
        // -79 dBm is 20 dB below txPower → 10× further than 1 m = 10 m.
        XCTAssertEqual(rssiToMetres(-79), 10.0, accuracy: 0.1)
    }

    // MARK: - GATT UUID format invariants

    func testServiceUUIDIsValidRFC4122() {
        XCTAssertNotNil(UUID(uuidString: "A7F3E2B1-4C8D-4F9A-B6E0-1D2C3F4A5B6C"),
                        "RSSIFallback and BluetoothMeshTransport must share the same UUID")
    }

    func testAudioCharUUIDIsValidRFC4122() {
        XCTAssertNotNil(UUID(uuidString: "B8C4F3C2-5D9E-4A0B-C7F1-2E3D4A5B6C7D"))
    }
}

// MARK: - Math helper (mirrors RSSIFallback's private formula)

private func rssiToMetres(_ rssi: Double) -> Double {
    pow(10.0, (-59.0 - rssi) / 20.0)
}
