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

    // MARK: - MFCC constants

    /// Window size for FFT — nearest power-of-2 that covers 20 ms @ 48 kHz (960 samples).
    private static let fftSize: Int = 1024
    private static let numMelBands: Int = 26
    private static let numCoefficients: Int = 8

    // MARK: - Shared FFT setup (created once)

    private static let fftSetup: vDSP_DFT_Setup? = {
        vDSP_DFT_zop_CreateSetup(
            nil,
            vDSP_Length(fftSize),
            vDSP_DFT_Direction.FORWARD
        )
    }()

    private static let melFilterbank: [[Float]] = buildMelFilterbank()

    // MARK: - FingerPrint

    struct FingerPrint: Sendable {
        let timestamp: TimeInterval
        let mfcc: [Float]   // 8 coefficients

        // MARK: compute

        static func compute(from buffer: AVAudioPCMBuffer) -> FingerPrint {
            let timestamp = CACurrentMediaTime()

            guard
                let floatData = buffer.floatChannelData,
                buffer.frameLength > 0,
                let setup = DuplicateVoiceSuppressor.fftSetup
            else {
                return FingerPrint(timestamp: timestamp, mfcc: Array(repeating: 0, count: numCoefficients))
            }

            let n = DuplicateVoiceSuppressor.fftSize
            let frameCount = Int(buffer.frameLength)
            let windowedCount = min(frameCount, n)

            // ── 1. Apply a Hann window to the first `n` samples ──────────────
            var windowed = [Float](repeating: 0, count: n)
            var hannWindow = [Float](repeating: 0, count: windowedCount)
            vDSP_hann_window(&hannWindow, vDSP_Length(windowedCount), Int32(vDSP_HANN_NORM))
            vDSP_vmul(floatData[0], 1, hannWindow, 1, &windowed, 1, vDSP_Length(windowedCount))

            // ── 2. Pack into split-complex buffers ────────────────────────────
            var realIn  = [Float](repeating: 0, count: n)
            let imagIn  = [Float](repeating: 0, count: n)
            var realOut = [Float](repeating: 0, count: n)
            var imagOut = [Float](repeating: 0, count: n)
            realIn = windowed   // imagIn stays zero (purely real input)

            vDSP_DFT_Execute(setup, realIn, imagIn, &realOut, &imagOut)

            // ── 3. Compute power spectrum for positive frequencies ─────────────
            let halfN = n / 2
            var power = [Float](repeating: 0, count: halfN)
            for i in 0..<halfN {
                power[i] = realOut[i] * realOut[i] + imagOut[i] * imagOut[i]
            }

            // ── 4. Apply mel filterbank → log power per mel band ──────────────
            let filterbank = DuplicateVoiceSuppressor.melFilterbank
            let numBands = filterbank.count
            var melPower = [Float](repeating: 0, count: numBands)
            for b in 0..<numBands {
                var sum: Float = 0
                vDSP_dotpr(power, 1, filterbank[b], 1, &sum, vDSP_Length(halfN))
                melPower[b] = log(max(sum, 1e-10))
            }

            // ── 5. DCT-II to get cepstral coefficients ────────────────────────
            var dct = [Float](repeating: 0, count: numBands)
            let piOverN = Float.pi / Float(numBands)
            for k in 0..<numBands {
                var coeff: Float = 0
                for n in 0..<numBands {
                    coeff += melPower[n] * cos(piOverN * (Float(n) + 0.5) * Float(k))
                }
                dct[k] = coeff
            }

            // Take the first `numCoefficients` coefficients (skip DC at index 0)
            let mfcc = Array(dct[1..<(1 + numCoefficients)])

            return FingerPrint(timestamp: timestamp, mfcc: mfcc)
        }

        // MARK: correlation

        func correlation(with other: FingerPrint) -> Float {
            let count = min(mfcc.count, other.mfcc.count)
            guard count > 0 else { return 0 }

            // Normalised cosine similarity
            var dot: Float = 0
            var normA: Float = 0
            var normB: Float = 0
            vDSP_dotpr(mfcc, 1, other.mfcc, 1, &dot, vDSP_Length(count))
            vDSP_svesq(mfcc, 1, &normA, vDSP_Length(count))
            vDSP_svesq(other.mfcc, 1, &normB, vDSP_Length(count))

            let denom = sqrt(normA) * sqrt(normB)
            guard denom > 1e-10 else { return 0 }
            return dot / denom
        }
    }

    // MARK: - Ring buffer

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

    // MARK: - Mel filterbank builder

    /// Builds a triangular mel filterbank for the given FFT parameters.
    private static func buildMelFilterbank() -> [[Float]] {
        let sampleRate = Float(LatencyBudget.audioSampleRate)
        let halfN = fftSize / 2
        let freqResolution = sampleRate / Float(fftSize)

        // Mel scale helpers
        func hzToMel(_ hz: Float) -> Float { 2595 * log10(1 + hz / 700) }
        func melToHz(_ mel: Float) -> Float { 700 * (pow(10, mel / 2595) - 1) }

        let lowFreqHz: Float = 80
        let highFreqHz: Float = min(8000, sampleRate / 2)
        let lowMel = hzToMel(lowFreqHz)
        let highMel = hzToMel(highFreqHz)

        // numMelBands + 2 equally spaced mel points
        var melPoints = [Float](repeating: 0, count: numMelBands + 2)
        for i in 0..<(numMelBands + 2) {
            melPoints[i] = melToHz(lowMel + Float(i) * (highMel - lowMel) / Float(numMelBands + 1))
        }

        // Convert mel-centre frequencies to FFT bin indices
        var binPoints = [Int](repeating: 0, count: numMelBands + 2)
        for i in 0..<(numMelBands + 2) {
            binPoints[i] = min(halfN - 1, Int((melPoints[i] / freqResolution).rounded()))
        }

        // Build triangular filters
        var filterbank = [[Float]](repeating: [Float](repeating: 0, count: halfN), count: numMelBands)
        for m in 0..<numMelBands {
            let lo = binPoints[m]
            let center = binPoints[m + 1]
            let hi = binPoints[m + 2]
            for k in lo..<center {
                if center > lo {
                    filterbank[m][k] = Float(k - lo) / Float(center - lo)
                }
            }
            for k in center..<hi {
                if hi > center {
                    filterbank[m][k] = Float(hi - k) / Float(hi - center)
                }
            }
        }
        return filterbank
    }
}
