import Foundation

/// Adaptive jitter buffer. §4.3 — buffers incoming frames to absorb network jitter,
/// adapts depth based on measured inter-arrival jitter, advances on concealment.
final class JitterBuffer: @unchecked Sendable {
    enum Tier { case excellent, good, fair, poor }

    /// How far ahead of `nextExpected` the oldest buffered frame may sit before
    /// we treat the gap as "lost sync" instead of "lost packet". Three 10 ms
    /// frames of concealment is still inaudible; beyond that, counting upwards
    /// one frame per tick would never catch up.
    static let maxConcealGap: Int64 = 3

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

    func advanceOnConceal() {
        lock.lock()
        defer { lock.unlock() }
        // Nothing has ever been received: there is no stream to conceal, so
        // don't let the drain timer run the counter away from the sender.
        guard hasReceivedFrame else { return }
        nextExpected &+= 1
        resyncIfStalledLocked()
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

    /// Concealing one or two lost packets is normal. But when the buffer holds
    /// only frames far away from `nextExpected` — sender restarted numbering,
    /// or we concealed through a long stall — snap to the oldest frame we
    /// actually hold instead of counting into the void one tick at a time.
    private func resyncIfStalledLocked() {
        guard buffer[nextExpected] == nil, let oldest = buffer.keys.min() else { return }
        let distance = Int64(oldest) - Int64(nextExpected)
        guard distance < 0 || distance > Self.maxConcealGap else { return }
        nextExpected = oldest
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
