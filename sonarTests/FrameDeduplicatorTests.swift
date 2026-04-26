import XCTest
@testable import Sonar

final class FrameDeduplicatorTests: XCTestCase {

    private func makeFrame(seq: UInt32) -> AudioFrame {
        AudioFrame(seq: seq, timestamp: 0, payload: Data([0x01]))
    }

    // MARK: - First frame passes through

    func testFirstFrameIsAllowed() {
        let dedup = FrameDeduplicator()
        let frame = makeFrame(seq: 1)
        let result = dedup.receive(frame)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.seq, 1)
    }

    // MARK: - Duplicate is rejected

    func testDuplicateSeqIsRejected() {
        let dedup = FrameDeduplicator()
        let frame = makeFrame(seq: 5)
        XCTAssertNotNil(dedup.receive(frame))
        XCTAssertNil(dedup.receive(frame), "Duplicate frame should return nil")
    }

    func testDuplicateDifferentPayloadSameSeqIsRejected() {
        let dedup = FrameDeduplicator()
        XCTAssertNotNil(dedup.receive(AudioFrame(seq: 10, payload: Data([0xAA]))))
        XCTAssertNil(dedup.receive(AudioFrame(seq: 10, payload: Data([0xBB]))),
                     "Same seq with different payload should still be rejected")
    }

    // MARK: - Different seq numbers are all allowed

    func testDifferentSeqsAllPass() {
        let dedup = FrameDeduplicator()
        for seq in UInt32(0)..<UInt32(10) {
            let result = dedup.receive(makeFrame(seq: seq))
            XCTAssertNotNil(result, "Frame with seq \(seq) should pass")
        }
    }

    // MARK: - Capacity eviction

    func testCapacityEvictionAllowsOldSeqAgain() {
        let capacity = 5
        let dedup = FrameDeduplicator(capacity: capacity)

        // Fill the deduplicator to capacity
        for seq in UInt32(0)..<UInt32(capacity) {
            XCTAssertNotNil(dedup.receive(makeFrame(seq: seq)))
        }

        // seq 0 is still remembered; sending again should be rejected
        XCTAssertNil(dedup.receive(makeFrame(seq: 0)),
                     "seq 0 should still be in the seen-set (capacity not exceeded yet)")

        // Adding one more (seq = capacity) causes eviction of seq 0
        XCTAssertNotNil(dedup.receive(makeFrame(seq: UInt32(capacity))))

        // Now seq 0 is forgotten and should be allowed again
        XCTAssertNotNil(dedup.receive(makeFrame(seq: 0)),
                        "After eviction seq 0 should be allowed through again")
    }

    func testCapacityEvictionFIFOOrder() {
        let capacity = 3
        let dedup = FrameDeduplicator(capacity: capacity)

        // Insert seqs 0, 1, 2
        for seq in UInt32(0)..<UInt32(capacity) {
            _ = dedup.receive(makeFrame(seq: seq))
        }
        // Insert seq 3 → evicts seq 0
        _ = dedup.receive(makeFrame(seq: 3))
        // seq 1 must still be remembered
        XCTAssertNil(dedup.receive(makeFrame(seq: 1)))
        // seq 0 must be forgotten
        XCTAssertNotNil(dedup.receive(makeFrame(seq: 0)))
    }

    // MARK: - reset()

    func testResetClearsSeenSet() {
        let dedup = FrameDeduplicator()
        _ = dedup.receive(makeFrame(seq: 99))
        dedup.reset()
        // After reset seq 99 should pass through again
        XCTAssertNotNil(dedup.receive(makeFrame(seq: 99)),
                        "After reset, previously seen seq should be accepted")
    }

    func testResetAllowsAllSeqsAgain() {
        let dedup = FrameDeduplicator()
        for seq in UInt32(0)..<UInt32(20) {
            _ = dedup.receive(makeFrame(seq: seq))
        }
        dedup.reset()
        for seq in UInt32(0)..<UInt32(20) {
            XCTAssertNotNil(dedup.receive(makeFrame(seq: seq)),
                            "After reset all seqs should be accepted")
        }
    }
}
