import AVFoundation
import Foundation

/// V01 — Ring buffer that always holds the last 200ms of audio before capture starts.
/// Prevents the first syllable from being cut off when PTT is pressed or session begins.
final class PreCaptureBuffer: @unchecked Sendable {
    private let capacity: Int               // frames
    private var buffer: [AVAudioPCMBuffer] = []
    private let lock = NSLock()

    init(durationMs: Int = 200, sampleRate: Double = 48_000, frameMs: Int = 10) {
        capacity = (durationMs / frameMs)
    }

    func push(_ frame: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(frame)
        if buffer.count > capacity { buffer.removeFirst() }
    }

    /// Drain buffered frames oldest-first. Call once when recording starts.
    func drain() -> [AVAudioPCMBuffer] {
        lock.lock(); defer { lock.unlock() }
        let result = buffer
        buffer.removeAll()
        return result
    }
}
