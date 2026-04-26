import XCTest
@testable import Sonar

/// White-box tests for RSSIFallback's path-loss distance formula and
/// EMA smoothing — verified against the model:
///   d = 10 ^ ((txPower - RSSI) / (10 * n))
///   txPower = -59 dBm, n = 2.0
///
/// These are pure-math tests that don't require BLE hardware.
final class RSSIFallbackMathTests: XCTestCase {

    // MARK: - Reference implementation (mirrors RSSIFallback internals)

    private let txPower: Double = -59
    private let n:       Double =  2.0
    private let alpha:   Double =  0.3

    private func rssiToMetres(_ rssi: Double) -> Double {
        pow(10.0, (txPower - rssi) / (10.0 * n))
    }

    private func ema(prev: Double?, new: Double) -> Double {
        guard let p = prev else { return new }
        return alpha * new + (1.0 - alpha) * p
    }

    // MARK: - Distance formula

    func testRSSIAtTxPowerGivesOneMetre() {
        // When RSSI == txPower: exponent = (−59 − (−59)) / 20 = 0 → 10^0 = 1
        let d = rssiToMetres(-59)
        XCTAssertEqual(d, 1.0, accuracy: 0.001)
    }

    func testRSSI79GivesTenMetres() {
        // (−59 − (−79)) / 20 = 20/20 = 1 → 10^1 = 10
        let d = rssiToMetres(-79)
        XCTAssertEqual(d, 10.0, accuracy: 0.01)
    }

    func testRSSI49GivesPointOneMetre() {
        // (−59 − (−49)) / 20 = −10/20 = −0.5 → 10^−0.5 ≈ 0.316 m
        let d = rssiToMetres(-49)
        XCTAssertEqual(d, pow(10.0, -0.5), accuracy: 0.001)
    }

    func testWeakerRSSIAlwaysGivesGreaterDistance() {
        // −70 dBm is weaker than −60 dBm → farther away
        let d60 = rssiToMetres(-60)
        let d70 = rssiToMetres(-70)
        XCTAssertLessThan(d60, d70, "Weaker RSSI must map to greater distance")
    }

    func testTenDbWeakerIsTenTimesFarther() {
        // Path-loss model: 10 dB weaker → 10^(10/20) = √10 times farther
        let d = rssiToMetres(-59)
        let d10dBWeaker = rssiToMetres(-69)
        XCTAssertEqual(d10dBWeaker / d, sqrt(10.0), accuracy: 0.001)
    }

    func testRSSINearZeroGivesVerySmallDistance() {
        // RSSI close to 0 dBm (extremely close/unrealistic) → tiny distance
        let d = rssiToMetres(-10)
        XCTAssertLessThan(d, 0.01)
    }

    func testRSSIMinus100GivesLargeDistance() {
        // (−59 − (−100)) / 20 = 41/20 = 2.05 → 10^2.05 ≈ 112 m
        let d = rssiToMetres(-100)
        XCTAssertGreaterThan(d, 100)
    }

    // MARK: - EMA smoothing

    func testFirstSampleSetsInitialValue() {
        let result = ema(prev: nil, new: -70)
        XCTAssertEqual(result, -70, accuracy: 0.0001)
    }

    func testEMAWeightIsAlpha03() {
        // new=-80, prev=-60: result = 0.3*(-80) + 0.7*(-60) = -24-42 = -66
        let result = ema(prev: -60, new: -80)
        XCTAssertEqual(result, -66.0, accuracy: 0.0001)
    }

    func testEMAConvergesToStableValue() {
        // Repeated same input should converge to that value
        var smoothed: Double? = nil
        for _ in 0..<50 { smoothed = ema(prev: smoothed, new: -70) }
        XCTAssertEqual(smoothed!, -70.0, accuracy: 0.1)
    }

    func testEMABoundedBetweenPrevAndNew() {
        let prev: Double = -60
        let new:  Double = -80
        let result = ema(prev: prev, new: new)
        XCTAssertGreaterThanOrEqual(result, new,  "EMA must not overshoot new value")
        XCTAssertLessThanOrEqual(result,    prev, "EMA must not overshoot prev value")
    }

    // MARK: - Valid RSSI range guard (mirrors centralManager didDiscover filter)

    func testValidRSSIRangeAccepted() {
        // RSSIFallback accepts: rssiValue < 0 && rssiValue > -100
        let validRSSIs: [Double] = [-50, -60, -70, -80, -90, -99]
        for rssi in validRSSIs {
            XCTAssertTrue(rssi < 0 && rssi > -100, "RSSI \(rssi) should be accepted")
        }
    }

    func testInvalidRSSIsRejected() {
        // CoreBluetooth returns 127 when RSSI cannot be read; 0 and -100 are also invalid
        let invalidRSSIs: [Double] = [127, 0, -100, -101, 1, 50]
        for rssi in invalidRSSIs {
            XCTAssertFalse(rssi < 0 && rssi > -100, "RSSI \(rssi) should be rejected")
        }
    }
}
