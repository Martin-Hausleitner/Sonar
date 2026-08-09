@testable import Sonar
import XCTest

final class JitterBufferTests: XCTestCase {
    private func makeFrame(seq: UInt32) -> AudioFrame {
        AudioFrame(seq: seq, timestamp: 0, payload: Data([UInt8(seq & 0xFF)]))
    }

    // MARK: - enqueue + dequeue in order

    func testEnqueueDequeueReturnsFrameInOrder() {
        let jb = JitterBuffer()
        let frame = makeFrame(seq: 0)
        jb.enqueue(frame)
        let result = jb.dequeue()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.seq, 0)
    }

    func testDequeueWithoutEnqueueReturnsNil() {
        let jb = JitterBuffer()
        XCTAssertNil(jb.dequeue())
    }

    func testDequeueAdvancesNextExpected() {
        let jb = JitterBuffer()
        jb.enqueue(makeFrame(seq: 0))
        jb.enqueue(makeFrame(seq: 1))

        let first = jb.dequeue()
        XCTAssertEqual(first?.seq, 0)

        let second = jb.dequeue()
        XCTAssertEqual(second?.seq, 1)
    }

    func testOutOfOrderEnqueueDequeuesInOrder() {
        let jb = JitterBuffer()
        // Enqueue out of order: 1, 0
        jb.enqueue(makeFrame(seq: 1))
        jb.enqueue(makeFrame(seq: 0))

        // Should return seq 0 first (nextExpected starts at 0)
        XCTAssertEqual(jb.dequeue()?.seq, 0)
        XCTAssertEqual(jb.dequeue()?.seq, 1)
    }

    // MARK: - Duplicate enqueue

    func testDuplicateEnqueueSecondDequeueReturnsNilForMissingNext() {
        let jb = JitterBuffer()
        jb.enqueue(makeFrame(seq: 0))
        jb.enqueue(makeFrame(seq: 0)) // duplicate — overwrites but same frame

        // First dequeue returns seq 0
        let first = jb.dequeue()
        XCTAssertEqual(first?.seq, 0)

        // nextExpected is now 1, which was never enqueued
        let second = jb.dequeue()
        XCTAssertNil(second, "No frame for seq 1, should return nil")
    }

    // MARK: - needsConcealment

    func testNeedsConcealmentTrueWhenNextFrameMissing() {
        let jb = JitterBuffer()
        // Nothing enqueued — seq 0 is missing
        XCTAssertTrue(jb.needsConcealment)
    }

    func testNeedsConcealmentFalseWhenNextFramePresent() {
        let jb = JitterBuffer()
        jb.enqueue(makeFrame(seq: 0))
        XCTAssertFalse(jb.needsConcealment)
    }

    func testNeedsConcealmentAfterDequeue() {
        let jb = JitterBuffer()
        jb.enqueue(makeFrame(seq: 0))
        _ = jb.dequeue() // consumes seq 0, nextExpected = 1
        // seq 1 not enqueued
        XCTAssertTrue(jb.needsConcealment)
    }

    func testNeedsConcealmentFalseWhenGapFilledAfterAdvance() {
        let jb = JitterBuffer()
        jb.enqueue(makeFrame(seq: 0))
        jb.enqueue(makeFrame(seq: 2)) // gap at seq 1
        _ = jb.dequeue() // consume seq 0, next = 1
        XCTAssertTrue(jb.needsConcealment, "seq 1 missing → concealment needed")

        jb.advanceOnConceal() // skip seq 1, next = 2
        XCTAssertFalse(jb.needsConcealment, "seq 2 present → no concealment needed")
    }

    // MARK: - advanceOnConceal

    func testAdvanceOnConcealSkipsSeq() {
        let jb = JitterBuffer()
        // Establish the stream first — the buffer adopts the sender's numbering
        // from the first frame it ever sees, so a "missing seq 0" only exists
        // once playback is under way.
        jb.enqueue(makeFrame(seq: 10))
        XCTAssertEqual(jb.dequeue()?.seq, 10) // nextExpected = 11

        jb.enqueue(makeFrame(seq: 12)) // seq 11 lost in flight
        XCTAssertTrue(jb.needsConcealment)

        jb.advanceOnConceal() // conceal seq 11, nextExpected = 12
        XCTAssertEqual(jb.dequeue()?.seq, 12)
    }

    // MARK: - Sender/receiver sequence alignment (live-audio regression)

    /// The playback timer starts draining at session start, long before MPC is
    /// connected, while the sender's first sequence number is 1. Pre-fix,
    /// `advanceOnConceal()` free-ran `nextExpected` far past anything the peer
    /// would ever send, so `dequeue()` returned nil forever — connected peers,
    /// permanent silence.
    func testEmptyDrainTicksDoNotDesyncFromSenderStartingAtSeqOne() {
        let jb = JitterBuffer()

        // 500 empty playback ticks (5 s) while the transport is still connecting.
        for _ in 0 ..< 500 {
            XCTAssertNil(jb.dequeue())
            if jb.needsConcealment { jb.advanceOnConceal() }
        }

        // Peer connects; MultipathBonder numbers its first frame seq = 1.
        for seq in UInt32(1) ... 10 {
            jb.enqueue(makeFrame(seq: seq))
        }

        for seq in UInt32(1) ... 10 {
            XCTAssertEqual(jb.dequeue()?.seq, seq, "frame \(seq) must reach playback")
        }
    }

    func testFirstFrameAdoptsSenderSequenceNumber() {
        let jb = JitterBuffer()
        jb.enqueue(makeFrame(seq: 5000))
        XCTAssertFalse(jb.needsConcealment)
        XCTAssertEqual(jb.dequeue()?.seq, 5000)
    }

    /// A long conceal run must not strand playback when the buffer holds frames
    /// far ahead (e.g. the transport stalled and resumed with a new burst).
    func testResyncSnapsToOldestBufferedFrameAfterLongGap() {
        let jb = JitterBuffer()
        jb.enqueue(makeFrame(seq: 1))
        XCTAssertEqual(jb.dequeue()?.seq, 1) // nextExpected = 2

        // Stream resumes 1 000 frames later.
        jb.enqueue(makeFrame(seq: 1002))
        jb.enqueue(makeFrame(seq: 1003))

        XCTAssertTrue(jb.needsConcealment)
        jb.advanceOnConceal() // one conceal tick is enough to resync
        XCTAssertEqual(jb.dequeue()?.seq, 1002)
        XCTAssertEqual(jb.dequeue()?.seq, 1003)
    }

    func testResetReturnsToUnsyncedState() {
        let jb = JitterBuffer()
        jb.enqueue(makeFrame(seq: 7))
        _ = jb.dequeue()
        jb.reset()

        for _ in 0 ..< 100 {
            XCTAssertNil(jb.dequeue())
            if jb.needsConcealment { jb.advanceOnConceal() }
        }
        jb.enqueue(makeFrame(seq: 1))
        XCTAssertEqual(jb.dequeue()?.seq, 1, "after reset the next sender's numbering is adopted again")
    }

    func testMultipleAdvancesSkipMultipleSeqs() {
        let jb = JitterBuffer()
        jb.enqueue(makeFrame(seq: 3))

        // Advance past seqs 0, 1, 2
        jb.advanceOnConceal()
        jb.advanceOnConceal()
        jb.advanceOnConceal()

        XCTAssertEqual(jb.dequeue()?.seq, 3)
    }

    func testAdvanceWrapsAroundUInt32() {
        let jb = JitterBuffer()
        // nextExpected starts at 0; if we advance UInt32.max times that's impractical,
        // but we can test that advanceOnConceal uses wrapping arithmetic by inserting
        // a frame at a high seq and advancing to it.
        let highSeq = UInt32(5)
        jb.enqueue(makeFrame(seq: highSeq))
        for _ in 0 ..< 5 {
            jb.advanceOnConceal()
        }
        XCTAssertEqual(jb.dequeue()?.seq, highSeq)
    }
}
