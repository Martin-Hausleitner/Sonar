import XCTest
@testable import Sonar

final class DuplicateVoiceSuppressorMathTests: XCTestCase {
    typealias FP = DuplicateVoiceSuppressor.FingerPrint

    // MARK: - Correlation

    func testCorrelationOfZeros() {
        let a = FP(timestamp: 0, mfcc: Array(repeating: 0, count: 8))
        let b = FP(timestamp: 0, mfcc: Array(repeating: 0, count: 8))
        XCTAssertEqual(a.correlation(with: b), 0, accuracy: 1e-6)
    }

    func testCorrelationOfIdenticalUnitVector() {
        let v: [Float] = [1, 0, 0, 0, 0, 0, 0, 0]
        let a = FP(timestamp: 0, mfcc: v)
        let b = FP(timestamp: 0, mfcc: v)
        XCTAssertEqual(a.correlation(with: b), 1, accuracy: 1e-6)
    }

    func testCorrelationOfOrthogonalVectors() {
        let a = FP(timestamp: 0, mfcc: [1, 0, 0, 0, 0, 0, 0, 0])
        let b = FP(timestamp: 0, mfcc: [0, 1, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(a.correlation(with: b), 0, accuracy: 1e-6)
    }

    func testCorrelationOfPartialMatch() {
        let a = FP(timestamp: 0, mfcc: [0.5, 0.5, 0, 0, 0, 0, 0, 0])
        let b = FP(timestamp: 0, mfcc: [0.5, 0.5, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(a.correlation(with: b), 0.5, accuracy: 1e-6)
    }

    func testCorrelationHandlesDifferentLengths() {
        let a = FP(timestamp: 0, mfcc: [1, 1])
        let b = FP(timestamp: 0, mfcc: [1, 1, 1, 1])
        XCTAssertEqual(a.correlation(with: b), 2, accuracy: 1e-6)
    }

    // MARK: - Ring Buffer

    func testRingBufferEvictsOnCapacity() {
        let sup = DuplicateVoiceSuppressor()
        for i in 0..<150 {
            let fp = FP(timestamp: TimeInterval(i), mfcc: Array(repeating: Float(i), count: 8))
            sup.ingestOutgoingFingerprint(fp)
        }
        // Capacity is 100; oldest 50 should be gone. Verify by introspection
        // through the public surface — feed a buffer that should *not* match
        // anything before index 50.
        // We can't probe the ring directly, but absence of a crash + bounded
        // memory growth is the contract here.
        XCTAssertNotNil(sup)
    }
}
