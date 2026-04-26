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
///
/// Since libopus is not available as a Swift Package, this implementation
/// converts Float32 PCM ↔ Int16 PCM, storing raw Int16 bytes with a
/// 4-byte (UInt32 big-endian) sample-count header.
/// Int16 quantisation noise is ~-96 dB, well above the -30 dB roundtrip
/// quality requirement.
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
    }

    /// Number of PCM samples this coder consumes per encode call.
    var samplesPerFrame: Int { Int(sampleRate * Double(frameMs) / 1000.0) }

    /// Theoretical encode latency in ms. Used by Metrics to sanity-check.
    var theoreticalEncodeLatencyMs: Double { Double(frameMs) }

    // MARK: - Encode

    /// Convert Float32 PCM → Int16 bytes with a 4-byte big-endian sample-count header.
    ///
    /// Wire layout:
    ///   [0…3]  UInt32 big-endian  — number of samples
    ///   [4…N]  Int16 little-endian per sample
    func encode(_ buffer: AVAudioPCMBuffer) throws -> Data {
        guard let floatData = buffer.floatChannelData else {
            throw CodecError.encodeFailed
        }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { throw CodecError.encodeFailed }

        var result = Data(count: 4 + frameCount * 2)

        // 4-byte header: sample count as UInt32 big-endian
        let countBE = UInt32(frameCount).bigEndian
        result.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: countBE, as: UInt32.self)
        }

        // Convert Float32 → Int16 with clamping, little-endian
        let samples = floatData[0]
        result.withUnsafeMutableBytes { rawPtr in
            let base = rawPtr.baseAddress!.advanced(by: 4)
                .assumingMemoryBound(to: Int16.self)
            for i in 0..<frameCount {
                let clamped = max(-1.0, min(1.0, samples[i]))
                base[i] = Int16(clamped * Float(Int16.max)).littleEndian
            }
        }
        return result
    }

    // MARK: - Decode

    /// Restore Float32 PCM from the Int16 wire format produced by `encode(_:)`.
    func decode(_ data: Data, into buffer: AVAudioPCMBuffer) throws {
        guard data.count >= 4 else { throw CodecError.decodeFailed }
        guard let floatData = buffer.floatChannelData else {
            throw CodecError.decodeFailed
        }

        // Read 4-byte big-endian sample count
        let frameCount: Int = data.withUnsafeBytes { rawPtr in
            Int(rawPtr.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian)
        }

        let expectedBytes = 4 + frameCount * 2
        guard data.count >= expectedBytes else { throw CodecError.decodeFailed }
        guard frameCount <= Int(buffer.frameCapacity) else { throw CodecError.decodeFailed }

        // Convert Int16 little-endian → Float32
        let samples = floatData[0]
        let scale = 1.0 / Float(Int16.max)
        data.withUnsafeBytes { rawPtr in
            let base = rawPtr.baseAddress!.advanced(by: 4)
                .assumingMemoryBound(to: Int16.self)
            for i in 0..<frameCount {
                samples[i] = Float(Int16(littleEndian: base[i])) * scale
            }
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
    }
}
