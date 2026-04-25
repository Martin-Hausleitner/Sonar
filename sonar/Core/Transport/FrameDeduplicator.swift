import Foundation

/// Receives frames from all parallel paths and passes each sequence number through exactly once.
/// §2.4 — companion to MultipathBonder on the receive side.
final class FrameDeduplicator: @unchecked Sendable {
    private var seen = Set<UInt32>()
    private var seenOrdered: [UInt32] = []
    private let lock = NSLock()

    /// Maximum number of sequence numbers to remember (covers ~16s at 50fps).
    private let capacity: Int

    init(capacity: Int = 800) {
        self.capacity = capacity
    }

    /// Returns the frame if it is new, nil if it is a duplicate.
    func receive(_ frame: AudioFrame) -> AudioFrame? {
        lock.lock(); defer { lock.unlock() }
        guard !seen.contains(frame.seq) else { return nil }
        seen.insert(frame.seq)
        seenOrdered.append(frame.seq)
        if seenOrdered.count > capacity {
            let evicted = seenOrdered.removeFirst()
            seen.remove(evicted)
        }
        return frame
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        seen.removeAll()
        seenOrdered.removeAll()
    }
}
