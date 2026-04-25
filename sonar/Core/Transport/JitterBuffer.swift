import Foundation

/// Adaptive jitter buffer. §4.3 — buffers incoming frames to absorb network jitter,
/// adapts depth based on measured jitter, uses DRED recovery for missing frames.
final class JitterBuffer: @unchecked Sendable {
    enum Tier { case excellent, good, fair, poor }

    private var buffer: [UInt32: AudioFrame] = [:]
    private var nextExpected: UInt32 = 0
    private var jitterMs: Double = 0
    private let lock = NSLock()

    /// Current buffer depth in ms. Adapts automatically.
    private(set) var depthMs: Int = 60

    func enqueue(_ frame: AudioFrame) {
        lock.lock(); defer { lock.unlock() }
        buffer[frame.seq] = frame
        updateJitter(frame)
    }

    /// Dequeue the next in-order frame, or nil if not yet arrived.
    func dequeue() -> AudioFrame? {
        lock.lock(); defer { lock.unlock() }
        guard let frame = buffer[nextExpected] else { return nil }
        buffer.removeValue(forKey: nextExpected)
        nextExpected &+= 1
        return frame
    }

    /// True if a frame is overdue (gap in buffer, trigger PLC/DRED).
    var needsConcealment: Bool {
        lock.lock(); defer { lock.unlock() }
        return buffer[nextExpected] == nil
    }

    func advanceOnConceal() {
        lock.lock(); defer { lock.unlock() }
        nextExpected &+= 1
    }

    private func updateJitter(_ frame: AudioFrame) {
        // Exponential moving average of inter-arrival jitter.
        let arrivalMs = Double(mach_absolute_time()) / 1_000_000.0
        jitterMs = jitterMs * 0.9 + (arrivalMs.truncatingRemainder(dividingBy: 100)) * 0.1

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
