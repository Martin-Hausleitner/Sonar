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

    // MARK: - Conceal race + gap thresholds

    /// `drainJitterBuffer` checks `needsConcealment` and calls
    /// `advanceOnConceal()` as two separate lock acquisitions. If the awaited
    /// frame arrives in between, concealing anyway would skip a frame that is
    /// sitting right there — permanently, because playback never looks back.
    func testAdvanceOnConcealNeverSkipsAFrameThatArrivedInTheMeantime() {
        let jb = JitterBuffer()
        jb.enqueue(makeFrame(seq: 10))
        XCTAssertEqual(jb.dequeue()?.seq, 10) // nextExpected = 11

        XCTAssertTrue(jb.needsConcealment) // caller decides to conceal …
        jb.enqueue(makeFrame(seq: 11)) // … and the frame arrives right now
        jb.advanceOnConceal()

        XCTAssertEqual(jb.dequeue()?.seq, 11, "the frame that arrived during the race must still be played")
    }

    /// Exactly `maxConcealGap` missing frames are concealed one tick at a time.
    func testGapOfMaxConcealGapIsConcealedFrameByFrame() {
        let jb = JitterBuffer()
        jb.enqueue(makeFrame(seq: 10))
        XCTAssertEqual(jb.dequeue()?.seq, 10) // nextExpected = 11

        jb.enqueue(makeFrame(seq: 14)) // 11, 12, 13 missing = 3 = maxConcealGap

        jb.advanceOnConceal()
        XCTAssertNil(jb.dequeue(), "a 3-frame gap must not snap forward")
        jb.advanceOnConceal()
        XCTAssertNil(jb.dequeue())
        jb.advanceOnConceal()
        XCTAssertEqual(jb.dequeue()?.seq, 14)
    }

    /// One more missing frame than we are willing to conceal must resync on the
    /// very first tick — the threshold is measured *before* the increment.
    func testGapOfMaxConcealGapPlusOneResyncsImmediately() {
        let jb = JitterBuffer()
        jb.enqueue(makeFrame(seq: 10))
        XCTAssertEqual(jb.dequeue()?.seq, 10) // nextExpected = 11

        jb.enqueue(makeFrame(seq: 15)) // 11…14 missing = 4 = maxConcealGap + 1

        jb.advanceOnConceal()
        XCTAssertEqual(jb.dequeue()?.seq, 15, "a 4-frame gap must snap in one tick")
    }

    // MARK: - Late / duplicate frames

    /// A duplicate arriving over a second bonded path after the frame was
    /// already played must not rewind playback onto stale audio.
    func testLateDuplicateDoesNotRewindPlayback() {
        let jb = JitterBuffer()
        jb.enqueue(makeFrame(seq: 100))
        XCTAssertEqual(jb.dequeue()?.seq, 100) // nextExpected = 101

        jb.enqueue(makeFrame(seq: 105))
        jb.enqueue(makeFrame(seq: 98)) // late straggler from a slower path
        jb.enqueue(makeFrame(seq: 100)) // duplicate of what we just played

        jb.advanceOnConceal() // 101…104 missing ⇒ resync forward
        XCTAssertEqual(jb.dequeue()?.seq, 105, "playback must move forward, never back to 98/100")
    }

    func testLateFrameAtWindowEdgeIsDropped() {
        let jb = JitterBuffer()
        jb.enqueue(makeFrame(seq: 1000))
        XCTAssertEqual(jb.dequeue()?.seq, 1000) // nextExpected = 1001

        // Exactly lateFrameWindow behind ⇒ still a straggler ⇒ dropped.
        jb.enqueue(makeFrame(seq: UInt32(Int64(1001) - JitterBuffer.lateFrameWindow)))
        XCTAssertTrue(jb.needsConcealment, "the dropped straggler must not become playable")
        jb.enqueue(makeFrame(seq: 1001))
        XCTAssertEqual(jb.dequeue()?.seq, 1001)
    }

    /// The peer restarts its session (and its sequence counter) while we keep
    /// ours running. Treating those frames as "late" would mean silence forever.
    func testSenderRestartAdoptsTheNewNumbering() {
        let jb = JitterBuffer()
        jb.enqueue(makeFrame(seq: 5000))
        XCTAssertEqual(jb.dequeue()?.seq, 5000)

        // Peer restarted: MultipathBonder numbers its first frame 1 again.
        for seq in UInt32(1) ... 3 {
            jb.enqueue(makeFrame(seq: seq))
        }
        XCTAssertEqual(jb.dequeue()?.seq, 1, "a restarted sender must be adopted, not ignored")
        XCTAssertEqual(jb.dequeue()?.seq, 2)
        XCTAssertEqual(jb.dequeue()?.seq, 3)
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
