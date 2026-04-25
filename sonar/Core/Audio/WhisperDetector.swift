import AVFoundation
import Combine
import Foundation

/// V07 — Detects whispering (<40 dB SPL) and signals a +12 dB mic boost.
/// Measures RMS of each PCM buffer and computes a rolling average SPL.
final class WhisperDetector: @unchecked Sendable {
    let isWhispering = CurrentValueSubject<Bool, Never>(false)

    /// SPL threshold below which we consider the user to be whispering.
    private let whisperThresholdDbSPL: Float = 40.0
    private let boostdB: Float = 12.0
    private var rmsHistory: [Float] = []
    private let windowSize = 10   // ~100ms at 10ms frames
    private let lock = NSLock()

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        let rms = sqrt((0..<frameCount).reduce(0.0) { $0 + data[$1] * data[$1] } / Float(frameCount))
        let dbSPL: Float = rms > 0 ? 20.0 * log10(rms) + 94.0 : 0  // 94 dBSPL ref for 0 dBFS
        lock.lock()
        rmsHistory.append(dbSPL)
        if rmsHistory.count > windowSize { rmsHistory.removeFirst() }
        let avg = rmsHistory.reduce(0, +) / Float(rmsHistory.count)
        let whispering = avg < whisperThresholdDbSPL && avg > 20  // exclude total silence
        lock.unlock()
        if isWhispering.value != whispering { isWhispering.send(whispering) }
    }
}
