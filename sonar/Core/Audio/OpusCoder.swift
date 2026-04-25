import AVFoundation
import Foundation

/// Wraps libopus. Plan §10/3, RESEARCH.md §2, LATENCY.md.
///
/// Settings (defaults pulled from `LatencyBudget`):
///  - 48 kHz / mono
///  - 10 ms frames (was 20 ms — halved for latency)
///  - 24 kbps VBR
///  - Complexity 5 (balanced)
///  - DTX on
///  - FEC off for Near, on for Far (toggle via `enableFEC`)
final class OpusCoder {
    enum CodecError: Error { case notConfigured, encodeFailed, decodeFailed }

    let sampleRate: Double
    let frameMs: Int
    let bitrate: Int32
    let complexity: Int32
    var fecEnabled: Bool

    init(
        sampleRate: Double = LatencyBudget.audioSampleRate,
        frameMs: Int = LatencyBudget.audioFrameMs,
        bitrate: Int32 = LatencyBudget.opusBitrateBps,
        complexity: Int32 = LatencyBudget.opusComplexity,
        fecEnabled: Bool = LatencyBudget.opusFECEnabledNear
    ) {
        self.sampleRate = sampleRate
        self.frameMs = frameMs
        self.bitrate = bitrate
        self.complexity = complexity
        self.fecEnabled = fecEnabled
        // TODO §10/3: bridge libopus encoder/decoder.
    }

    /// Number of PCM samples this coder consumes per encode call.
    var samplesPerFrame: Int { Int(sampleRate * Double(frameMs) / 1000.0) }

    /// Theoretical encode latency in ms. Used by Metrics to sanity-check.
    var theoreticalEncodeLatencyMs: Double { Double(frameMs) }

    func encode(_ buffer: AVAudioPCMBuffer) throws -> Data {
        // TODO §10/3
        throw CodecError.notConfigured
    }

    func decode(_ data: Data, into buffer: AVAudioPCMBuffer) throws {
        // TODO §10/3
        throw CodecError.notConfigured
    }
}
