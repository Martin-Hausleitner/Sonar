import XCTest
@testable import Sonar

final class DuplicateVoiceSuppressorTests: XCTestCase {
    func testZeroFingerprintsCorrelateAtZero() {
        let a = DuplicateVoiceSuppressor.FingerPrint(timestamp: 0, mfcc: Array(repeating: 0, count: 8))
        let b = DuplicateVoiceSuppressor.FingerPrint(timestamp: 0, mfcc: Array(repeating: 0, count: 8))
        XCTAssertEqual(a.correlation(with: b), 0)
    }

    func testIdenticalUnitFingerprintsCorrelateHigh() {
        let v: [Float] = [1, 0, 0, 0, 0, 0, 0, 0]
        let a = DuplicateVoiceSuppressor.FingerPrint(timestamp: 0, mfcc: v)
        let b = DuplicateVoiceSuppressor.FingerPrint(timestamp: 0, mfcc: v)
        XCTAssertEqual(a.correlation(with: b), 1)
    }
}
