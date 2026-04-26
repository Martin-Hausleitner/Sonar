import Foundation

/// Adaptive jitter buffer. §4.3 — buffers incoming frames to absorb network jitter,
/// adapts depth based on measured inter-arrival jitter, advances on concealment.
final class JitterBuffer: @unchecked Sendable {
    enum Tier { case excellent, good, fair, poor }

    private var buffer: [UInt32: AudioFrame] = [:]
    private var nextExpected: UInt32 = 0

    /// Smoothed inter-arrival jitter in milliseconds (RFC 3550 §A.8 style EMA).
    private(set) var jitterMs: Double = 0

    private var lastArrivalMs: Double = 0
    private var timebaseInfo = mach_timebase_info_data_t()
    private let lock = NSLock()

    private(set) var depthMs: Int = 60

    func enqueue(_ frame: AudioFrame) {
        lock.lock(); defer { lock.unlock() }
        buffer[frame.seq] = frame
        updateJitter()
    }

    func dequeue() -> AudioFrame? {
        lock.lock(); defer { lock.unlock() }
        guard let frame = buffer[nextExpected] else { return nil }
        buffer.removeValue(forKey: nextExpected)
        nextExpected &+= 1
        return frame
    }

    var needsConcealment: Bool {
        lock.lock(); defer { lock.unlock() }
        return buffer[nextExpected] == nil
    }

    func advanceOnConceal() {
        lock.lock(); defer { lock.unlock() }
        nextExpected &+= 1
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        buffer.removeAll()
        nextExpected = 0
        jitterMs = 0
        lastArrivalMs = 0
        depthMs = 60
    }

    // MARK: - Private

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
        case .good:      60
        case .fair:      120
        case .poor:      200
        }
    }

    private var tier: Tier {
        switch jitterMs {
        case ..<5:  .excellent
        case ..<15: .good
        case ..<30: .fair
        default:    .poor
        }
    }
}
