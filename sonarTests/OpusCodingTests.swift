import XCTest
@testable import Sonar

final class OpusCodingTests: XCTestCase {
    func testCoderInitialises() {
        _ = OpusCoder()
    }

    func testDefaultsMatchLatencyBudget() {
        let c = OpusCoder()
        XCTAssertEqual(c.frameMs, LatencyBudget.audioFrameMs)
        XCTAssertEqual(c.sampleRate, LatencyBudget.audioSampleRate)
    }

    // TODO §10/3: round-trip a 1 kHz sine wave and assert reconstruction error <-30 dB.
}
