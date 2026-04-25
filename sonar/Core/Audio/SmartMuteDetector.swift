import AVFoundation
import Combine
import Foundation

/// V21 — Detects sneezing, coughing, eating sounds and auto-mutes for ~500ms.
/// Uses energy + spectral heuristics on the PCM buffer (no ML required).
final class SmartMuteDetector: @unchecked Sendable {
    let shouldMute = CurrentValueSubject<Bool, Never>(false)

    private var muteUntil: Date = .distantPast
    private let lock = NSLock()

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)

        // Impulsive-noise heuristic: if peak-to-RMS ratio is very high, it's
        // likely a transient (cough/sneeze/bite) rather than speech.
        let rms  = sqrt((0..<count).reduce(0.0) { $0 + data[$1] * data[$1] } / Float(count))
        let peak = (0..<count).map { abs(data[$0]) }.max() ?? 0
        let crestFactor = rms > 0 ? peak / rms : 0

        lock.lock()
        let now = Date()
        if crestFactor > 8.0 && rms > 0.02 {
            muteUntil = now.addingTimeInterval(0.5)
        }
        let mute = now < muteUntil
        lock.unlock()

        if shouldMute.value != mute { shouldMute.send(mute) }
    }
}
