import Foundation

/// Adaptive jitter buffer. §4.3 — buffers incoming frames to absorb network jitter,
/// adapts depth based on measured inter-arrival jitter, advances on concealment.
final class JitterBuffer: @unchecked Sendable {
    enum Tier { case excellent, good, fair, poor }

    /// How many consecutive frames we are willing to conceal one tick at a time
    /// before snapping to the oldest frame we actually hold. Three 10 ms frames
    /// of concealment is still inaudible; beyond that, counting upwards one
    /// frame per tick just adds latency without ever catching up.
    ///
    /// Measured **before** the conceal increment, so a gap of
    /// `maxConcealGap + 1` missing frames resyncs immediately.
    static let maxConcealGap: Int64 = 3

    /// How far behind `nextExpected` an arriving frame may be and still be
    /// treated as a late straggler (dropped). 200 frames = 2 s at 10 ms, which
    /// is far beyond any realistic MPC/BLE reordering window.
    ///
    /// Anything *further* behind is not a straggler but a sender that restarted
    /// its numbering (peer restarted its session while ours kept running), so
    /// the stream is adopted afresh instead of being ignored forever. This is
    /// also what makes the `UInt32` sequence wrap after ~497 days of continuous
    /// streaming self-healing: the wrapped frame looks like a restart and costs
    /// one buffer flush, not permanent silence.
    static let lateFrameWindow: Int64 = 200

    private var buffer: [UInt32: AudioFrame] = [:]
    private var nextExpected: UInt32 = 0

    /// `false` until the first frame ever arrives. The playback timer starts
    /// ticking at session start — long before MPC/BLE finish connecting — and
    /// pre-fix it free-ran `nextExpected` upward the whole time. Since the
    /// sender's first sequence number is 1 (`MultipathBonder.nextSeq`
    /// increments *before* returning), the two counters never met again and
    /// `dequeue()` returned nil forever: connected peers, permanent silence.
    private var hasReceivedFrame = false

    /// `true` once a frame has actually been handed to playback. Before that,
    /// a lower sequence number may still rewind `nextExpected` (frames can
    /// arrive out of order across bonded paths right at session start).
    private var hasDequeued = false

    /// Smoothed inter-arrival jitter in milliseconds (RFC 3550 §A.8 style EMA).
    private(set) var jitterMs: Double = 0

    private var lastArrivalMs: Double = 0
    private var timebaseInfo = mach_timebase_info_data_t()
    private let lock = NSLock()

    private(set) var depthMs: Int = 60

    func enqueue(_ frame: AudioFrame) {
        lock.lock()
        defer { lock.unlock() }

        if !hasReceivedFrame {
            // Adopt the sender's numbering instead of assuming it starts at 0.
            hasReceivedFrame = true
            nextExpected = frame.seq
        } else if !hasDequeued, frame.seq < nextExpected {
            // Startup burst arrived out of order — rewind to the oldest frame
            // as long as nothing has been played yet.
            nextExpected = frame.seq
        } else if hasDequeued {
            let offset = Int64(frame.seq) - Int64(nextExpected)
            if offset < 0 {
                guard offset < -Self.lateFrameWindow else {
                    // Late straggler or a duplicate from a second bonded path.
                    // Its playback slot is long gone; keeping it would let the
                    // resync path rewind playback onto stale audio (and would
                    // leak the entry, since `dequeue` never looks backwards).
                    return
                }
                // Too far behind to be reordering: the peer restarted its
                // session and its sequence counter with it. Adopt the new
                // stream — otherwise every future frame would look "late" and
                // playback would stay silent forever.
                buffer.removeAll()
                nextExpected = frame.seq
            }
        }

        buffer[frame.seq] = frame
        updateJitter()
    }

    func dequeue() -> AudioFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard let frame = buffer[nextExpected] else { return nil }
        buffer.removeValue(forKey: nextExpected)
        nextExpected &+= 1
        hasDequeued = true
        return frame
    }

    var needsConcealment: Bool {
        lock.lock()
        defer { lock.unlock() }
        return buffer[nextExpected] == nil
    }

    /// Skip the frame we are waiting for. Returns `false` when nothing was
    /// concealed, so the caller can skip scheduling a silence frame too.
    @discardableResult
    func advanceOnConceal() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // Nothing has ever been received: there is no stream to conceal, so
        // don't let the drain timer run the counter away from the sender.
        guard hasReceivedFrame else { return false }
        // The caller checks `needsConcealment` and then calls us in a second
        // step — the frame can arrive in between. Re-check under the same lock,
        // otherwise we would skip a frame that is sitting right there.
        guard buffer[nextExpected] == nil else { return false }
        // Measure the gap BEFORE advancing, so `maxConcealGap` counts *missing
        // frames* rather than "missing frames minus the one we just skipped".
        guard !resyncIfStalledLocked() else { return true }
        nextExpected &+= 1
        return true
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll()
        nextExpected = 0
        hasReceivedFrame = false
        hasDequeued = false
        jitterMs = 0
        lastArrivalMs = 0
        depthMs = 60
    }

    // MARK: - Private

    /// Concealing one or two lost packets is normal. But when the oldest frame
    /// we hold sits more than `maxConcealGap` frames ahead — we concealed
    /// through a long stall, or the transport resumed with a fresh burst —
    /// snap to it instead of counting into the void one tick at a time.
    ///
    /// Only ever moves **forward**: `enqueue` guarantees every buffered key is
    /// `>= nextExpected`, so a late duplicate can no longer rewind playback.
    /// Returns `true` when it resynced.
    private func resyncIfStalledLocked() -> Bool {
        guard buffer[nextExpected] == nil, let oldest = buffer.keys.min() else { return false }
        let missing = Int64(oldest) - Int64(nextExpected)
        guard missing > Self.maxConcealGap else { return false }
        nextExpected = oldest
        return true
    }

    private func currentMs() -> Double {
        if timebaseInfo.denom == 0 { mach_timebase_info(&timebaseInfo) }
        let ticks = mach_absolute_time()
        let ns = Double(ticks) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom)
        return ns / 1_000_000.0
    }

    private func updateJitter() {
        let now = currentMs()
        defer { lastArrivalMs = now }
        guard lastArrivalMs > 0 else { return }

        // Jitter = deviation from expected frame period.
        let interArrival = now - lastArrivalMs
        let expected = Double(LatencyBudget.audioFrameMs)
        let deviation = abs(interArrival - expected)
        jitterMs = jitterMs * 0.9 + deviation * 0.1

        depthMs = switch tier {
        case .excellent: 20
        case .good: 60
        case .fair: 120
        case .poor: 200
        }
    }

    private var tier: Tier {
        switch jitterMs {
        case ..<5: .excellent
        case ..<15: .good
        case ..<30: .fair
        default: .poor
        }
    }
}
