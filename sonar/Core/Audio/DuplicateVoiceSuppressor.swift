import AVFoundation
import Accelerate
import Foundation
import QuartzCore

/// The "doppel-Audio-Problem" solver. Plan §6.
///
/// Three mechanisms:
///  1. Distance gate (§10/6): mute remote voice when partner is physically close.
///  2. Voice-Processing-IO (handled by AudioEngine, §6.1).
///  3. Cross-Device fingerprint correlation (this class, §6.1 mech. 3).
final class DuplicateVoiceSuppressor {
    struct FingerPrint: Sendable {
        let timestamp: TimeInterval
        let mfcc: [Float]   // 8 coefficients

        static func compute(from buffer: AVAudioPCMBuffer) -> FingerPrint {
            // TODO §10/6: window 20 ms, FFT via vDSP, mel-warped log power, DCT, take 8 coeffs.
            return FingerPrint(timestamp: CACurrentMediaTime(), mfcc: Array(repeating: 0, count: 8))
        }

        func correlation(with other: FingerPrint) -> Float {
            var sum: Float = 0
            for i in 0..<min(mfcc.count, other.mfcc.count) {
                sum += mfcc[i] * other.mfcc[i]
            }
            return sum
        }
    }

    private var ring: [FingerPrint] = []
    private let capacity = 100
    private(set) var currentSuppression: Float = 1.0

    func ingestOutgoingFingerprint(_ fp: FingerPrint) {
        ring.append(fp)
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
    }

    func analyzeIncomingMic(_ buffer: AVAudioPCMBuffer) -> Float {
        let mic = FingerPrint.compute(from: buffer)
        let cutoff = mic.timestamp - 0.2
        let recent = ring.filter { $0.timestamp >= cutoff }
        let maxCorr = recent.map { mic.correlation(with: $0) }.max() ?? 0
        currentSuppression = maxCorr > 0.6 ? 0.03 : 1.0
        return currentSuppression
    }
}
