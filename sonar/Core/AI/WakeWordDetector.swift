import AVFoundation
import Combine
import Foundation

/// On-device "Hey Sonar" keyword detection. Plan §10/12.
///
/// Production: integrate Picovoice Porcupine with a custom keyword model.
/// Prototype: energy-based heuristic — fires when RMS crosses threshold
/// twice within 800 ms (approximates a two-syllable wake word pattern).
final class WakeWordDetector {
    let triggered = PassthroughSubject<Void, Never>()

    // Porcupine would replace these thresholds with ML inference.
    private let rmsThreshold: Float   = 0.04
    private let windowSec: Double     = 0.80   // two-hit window
    private var hitTimes: [Date]      = []
    private var isStarted: Bool       = false

    func start() {
        isStarted = true
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard isStarted,
              let data = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var sumSq: Float = 0
        for i in 0..<count { sumSq += data[i] * data[i] }
        let rms = sqrt(sumSq / Float(count))

        guard rms > rmsThreshold else { return }

        let now = Date()
        // Keep only hits within the detection window.
        hitTimes = hitTimes.filter { now.timeIntervalSince($0) < windowSec }
        hitTimes.append(now)

        // Two distinct energy spikes → treat as a two-syllable wake word.
        if hitTimes.count >= 2 {
            hitTimes.removeAll()
            triggered.send()
        }
    }

    func stop() {
        isStarted = false
        hitTimes.removeAll()
    }
}
