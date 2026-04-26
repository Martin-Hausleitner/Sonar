import Accelerate
import AVFoundation
import Foundation

/// Energy-based voice activity detector. Plan §8.2 trigger #2.
/// Uses per-frame RMS with hysteresis to avoid rapid toggling on consonant bursts.
final class VAD {
    private(set) var isSpeaking = false

    private let onThreshold: Float  = 0.018   // RMS to go speaking → on
    private let offThreshold: Float = 0.010   // RMS to go speaking → off (hysteresis gap)

    func feed(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return false }
        var meanSq: Float = 0
        vDSP_measqv(data, 1, &meanSq, vDSP_Length(buffer.frameLength))
        let rms = sqrt(meanSq)   // vDSP_measqv already returns mean (not sum) of squares

        if rms > onThreshold  { isSpeaking = true  }
        if rms < offThreshold { isSpeaking = false }
        return isSpeaking
    }

    func reset() { isSpeaking = false }
}
