import AVFoundation
import Accelerate
import Foundation
import QuartzCore

/// The "doppel-Audio-Problem" solver. Plan §6, LATENCY.md.
///
/// Latency-relevant choices:
///  - Correlation window 100 ms (was 200) — tight enough that the duck
///    happens before the partner's voice has fully echoed back.
///  - Threshold 0.6, gain on duck -30 dB — both pulled from LatencyBudget.
///  - Fingerprint compute is O(n·log n) FFT; runs on the audio thread, so
///    must complete inside the per-frame budget (~10 ms).
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
        let windowSec = Double(LatencyBudget.duplicateSuppressorWindowMs) / 1000.0
        let cutoff = mic.timestamp - windowSec
        let recent = ring.filter { $0.timestamp >= cutoff }
        let maxCorr = recent.map { mic.correlation(with: $0) }.max() ?? 0
        currentSuppression = maxCorr > LatencyBudget.duplicateSuppressorThreshold
            ? LatencyBudget.duplicateSuppressorGainOnDuck
            : 1.0
        return currentSuppression
    }
}
